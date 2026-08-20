#!/usr/bin/env python3
"""
desire_timing_test.py

Run locally. Directly drives DynamoDB for an ephemeral env MC to measure
end-to-end desire round-trip latency.

Flow:
  1. Parse .ephemeral-envs, pick a ready env (or use --env-id)
  2. Derive DynamoDB table names: eph-{id}-mc01-{specs|status}-{applydesires|readdesires}
  3. Write an ApplyDesire (ServerSideApply, ConfigMap) to the specs-applydesires table
  4. Write a ReadDesire for the same ConfigMap to the specs-readdesires table
  5. Poll status-applydesires until Successful=True  -> log timing
  6. Poll status-readdesires until populated         -> log timing
  7. Flip ApplyDesire to Type=Delete in specs table
  8. Poll status-applydesires until delete Successful=True -> log timing
  9. Delete ApplyDesire and ReadDesire from specs tables
 10. Print full timing summary

Usage:
  python3 desire_timing_test.py [--env-id <id>] [--mc mc01] [--profile <aws-profile>]
                                [--region <region>] [--namespace <ns>] [--no-cleanup]
                                [--timeout <seconds>] [--poll-interval <seconds>]
"""

import argparse
import json
import os
import re
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------


def parse_args():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument(
        "--env-id", help="Ephemeral env BUILD_ID (auto-detected if only one ready env)"
    )
    p.add_argument(
        "--mc", default="mc01", help="MC name within the eph env (default: mc01)"
    )
    p.add_argument(
        "--profile", help="AWS profile to use (default: current env / default profile)"
    )
    p.add_argument(
        "--region", help="AWS region (default: from .ephemeral-envs REGION field)"
    )
    p.add_argument(
        "--namespace",
        default="default",
        help="Namespace for the test ConfigMap on the MC",
    )
    p.add_argument(
        "--no-cleanup",
        action="store_true",
        help="Leave desire docs in DynamoDB after the run",
    )
    p.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Per-step poll timeout in seconds (default: 300)",
    )
    p.add_argument(
        "--poll-interval",
        type=float,
        default=2.0,
        help="Poll interval in seconds (default: 2)",
    )
    p.add_argument(
        "--envs-file", default=".ephemeral-envs", help="Path to .ephemeral-envs file"
    )
    return p.parse_args()


# ---------------------------------------------------------------------------
# .ephemeral-envs parsing
# ---------------------------------------------------------------------------


def parse_envs_file(path: str) -> list[dict]:
    """Parse .ephemeral-envs into a list of dicts."""
    envs = []
    try:
        lines = Path(path).read_text().splitlines()
    except FileNotFoundError:
        return []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        env = {"id": parts[0]}
        for part in parts[1:]:
            if "=" in part:
                k, v = part.split("=", 1)
                env[k] = v
        envs.append(env)
    return envs


def pick_env(envs: list[dict], env_id: str | None) -> dict:
    if env_id:
        matches = [e for e in envs if e["id"] == env_id]
        if not matches:
            die(f"No env with ID '{env_id}' found in .ephemeral-envs")
        return matches[0]

    ready = [e for e in envs if e.get("STATE") == "ready"]
    if not ready:
        die("No ready environments in .ephemeral-envs. Pass --env-id to override.")
    if len(ready) > 1:
        print("Multiple ready environments found:")
        for e in ready:
            print(
                f"  {e['id']}  REGION={e.get('REGION', '?')}  BRANCH={e.get('BRANCH', '?')}"
            )
        die("Pass --env-id <id> to select one.")
    return ready[0]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def die(msg: str):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def ts():
    return datetime.now().strftime("%H:%M:%S")


def log(msg):
    print(f"[{ts()}] {msg}")


def ok(msg):
    print(f"[{ts()}] OK   {msg}")


def warn(msg):
    print(f"[{ts()}] WARN {msg}")


def make_document_id() -> str:
    """Generate a random UUID v4 as the DynamoDB partition key."""
    return str(uuid.uuid4())


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def compute_shard(document_id: str, shard_count: int = 4) -> str:
    """
    Mirror of hyperfleet-dynamo ComputeShard (dynamodb/shard.go):
      1. Strip hyphens from the UUID string.
      2. Parse the first 8 hex characters as a base-16 uint64.
      3. Return str(value % shard_count).
    Items written without this attribute are invisible to the GSI poller.
    """
    stripped = document_id.replace("-", "")
    if len(stripped) < 8:
        return "0"
    try:
        v = int(stripped[:8], 16)
    except ValueError:
        return "0"
    return str(v % shard_count)


# ---------------------------------------------------------------------------
# DynamoDB item construction
# ---------------------------------------------------------------------------


def apply_desire_item(
    doc_id: str, cluster_name: str, namespace: str, cm_name: str
) -> dict:
    """
    Build a DynamoDB item for an ApplyDesire (ServerSideApply, ConfigMap).

    Top-level attributes written:
      documentID        S  — partition key
      shard             S  — GSI partition key (computed from documentID, required for GSI poller)
      version           N  — optimistic concurrency (start at 1)
      updateTime        S  — ISO-8601
      createTime        S  — ISO-8601
      spec              M  — nested map (managementCluster, clusterID, type, targetItem, serverSideApply)
      spec_kubeContent  S  — JSON string of the ConfigMap (kube-applier reads this attribute separately)
      status            M  — empty map
    """
    now = now_iso()
    cm_json = json.dumps(
        {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": cm_name, "namespace": namespace},
            "data": {"created-by": "desire-timing-test", "timestamp": now},
        }
    )
    return {
        "documentID": {"S": doc_id},
        "shard": {"S": compute_shard(doc_id)},
        "version": {"N": "1"},
        "updateTime": {"S": now},
        "createTime": {"S": now},
        "spec": {
            "M": {
                "managementCluster": {"S": cluster_name},
                "clusterID": {"S": "timing-test"},
                "type": {"S": "ServerSideApply"},
                "targetItem": {
                    "M": {
                        "group": {"S": ""},
                        "version": {"S": "v1"},
                        "resource": {"S": "configmaps"},
                        "namespace": {"S": namespace},
                        "name": {"S": cm_name},
                    }
                },
                "serverSideApply": {"M": {}},
            }
        },
        "spec_kubeContent": {"S": cm_json},
        "status": {"M": {}},
    }


def apply_desire_delete_item(existing_item: dict) -> dict:
    """
    Flip an existing ApplyDesire item to Type=Delete.
    Increments version, updates updateTime, recomputes shard, removes serverSideApply, sets type=Delete.
    """
    item = json.loads(json.dumps(existing_item))  # deep copy via JSON
    old_version = int(item["version"]["N"])
    item["version"] = {"N": str(old_version + 1)}
    new_time = now_iso()
    item["updateTime"] = {"S": new_time}
    item["shard"] = {"S": compute_shard(item["documentID"]["S"])}
    spec = item["spec"]["M"]
    spec["type"] = {"S": "Delete"}
    spec.pop("serverSideApply", None)
    item.pop("spec_kubeContent", None)
    return item


def read_desire_item(
    doc_id: str, cluster_name: str, namespace: str, cm_name: str
) -> dict:
    """
    Build a DynamoDB item for a ReadDesire targeting the same ConfigMap.
    """
    now = now_iso()
    return {
        "documentID": {"S": doc_id},
        "shard": {"S": compute_shard(doc_id)},
        "version": {"N": "1"},
        "updateTime": {"S": now},
        "createTime": {"S": now},
        "spec": {
            "M": {
                "managementCluster": {"S": cluster_name},
                "clusterID": {"S": "timing-test"},
                "targetItem": {
                    "M": {
                        "group": {"S": ""},
                        "version": {"S": "v1"},
                        "resource": {"S": "configmaps"},
                        "namespace": {"S": namespace},
                        "name": {"S": cm_name},
                    }
                },
            }
        },
        "status": {"M": {}},
    }


# ---------------------------------------------------------------------------
# Polling helpers
# ---------------------------------------------------------------------------


def poll_apply_status(
    ddb,
    table: str,
    doc_id: str,
    after_time: str | None,
    timeout: int,
    poll_interval: float,
    start: float,
) -> float | None:
    """
    Poll status-applydesires until Successful=True for the given doc_id.
    If after_time is provided (ISO-8601 string), also requires that
    observedDesireUpdateTime >= after_time, mirroring the operator's
    CheckApplyDesireStatuses staleness gate. This prevents a stale
    Successful=True condition from a prior reconciliation (e.g. the create)
    being accepted as confirmation of a subsequent delete.
    Returns elapsed_ms or None on timeout.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            resp = ddb.get_item(
                TableName=table,
                Key={"documentID": {"S": doc_id}},
                ConsistentRead=True,
            )
        except Exception as e:
            warn(f"get_item error: {e}")
            time.sleep(poll_interval)
            continue

        item = resp.get("Item", {})
        if item:
            status_map = item.get("status", {}).get("M", {})
            observed_time = status_map.get("observedDesireUpdateTime", {}).get("S", "")
            conditions = status_map.get("conditions", {}).get("L", [])
            for cond in conditions:
                m = cond.get("M", {})
                if (
                    m.get("Type", {}).get("S") == "Successful"
                    and m.get("Status", {}).get("S") == "True"
                    and (after_time is None or observed_time >= after_time)
                ):
                    return (time.monotonic() - start) * 1000
        time.sleep(poll_interval)
    return None


def poll_read_status(
    ddb, table: str, doc_id: str, timeout: int, poll_interval: float, start: float
) -> float | None:
    """
    Poll status-readdesires until status_kubeContent is populated.
    Returns elapsed_ms or None on timeout.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            resp = ddb.get_item(
                TableName=table,
                Key={"documentID": {"S": doc_id}},
                ConsistentRead=True,
            )
        except Exception as e:
            warn(f"get_item error: {e}")
            time.sleep(poll_interval)
            continue

        item = resp.get("Item", {})
        if item and "status_kubeContent" in item:
            return (time.monotonic() - start) * 1000
        time.sleep(poll_interval)
    return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    args = parse_args()

    # -- boto3 import (defer so error is clear) --
    try:
        import boto3
    except ImportError:
        die("boto3 is not installed. Run: pip install boto3")

    # -- resolve env --
    envs = parse_envs_file(args.envs_file)
    env = pick_env(envs, args.env_id)
    env_id = env["id"]
    region = args.region or env.get("REGION", "us-east-1")

    # Table name pattern: eph-{id}-{mc}-{specs|status}-{applydesires|readdesires}
    cluster_name = f"eph-{env_id}-{args.mc}"
    specs_prefix = f"{cluster_name}-specs"
    status_prefix = f"{cluster_name}-status"
    tbl_specs_apply = f"{specs_prefix}-applydesires"
    tbl_specs_read = f"{specs_prefix}-readdesires"
    tbl_status_apply = f"{status_prefix}-applydesires"
    tbl_status_read = f"{status_prefix}-readdesires"

    cm_name = f"timing-test-{env_id[:6]}"

    log(f"Ephemeral env   : {env_id}")
    log(f"MC cluster name : {cluster_name}")
    log(f"Region          : {region}")
    log(f"ConfigMap       : {args.namespace}/{cm_name}")
    log(f"Specs tables    : {tbl_specs_apply}, {tbl_specs_read}")
    log(f"Status tables   : {tbl_status_apply}, {tbl_status_read}")
    print()

    # -- boto3 session --
    session_kwargs = {"region_name": region}
    if args.profile:
        session_kwargs["profile_name"] = args.profile
    session = boto3.Session(**session_kwargs)
    ddb = session.client("dynamodb")

    # -- generate document IDs --
    apply_doc_id = make_document_id()
    read_doc_id = make_document_id()
    log(f"ApplyDesire doc ID : {apply_doc_id}")
    log(f"ReadDesire  doc ID : {read_doc_id}")
    print()

    timings = {}
    overall_start = time.monotonic()

    # ------------------------------------------------------------------ #
    # Step 1: Write ApplyDesire (ServerSideApply)                         #
    # ------------------------------------------------------------------ #
    log("Step 1: Writing ApplyDesire (ServerSideApply) to specs table...")
    apply_item = apply_desire_item(apply_doc_id, cluster_name, args.namespace, cm_name)
    t0 = time.monotonic()
    ddb.put_item(TableName=tbl_specs_apply, Item=apply_item)
    timings["write_apply_desire_ms"] = (time.monotonic() - t0) * 1000
    ok(f"ApplyDesire written  (+{timings['write_apply_desire_ms']:.0f}ms)")

    # ------------------------------------------------------------------ #
    # Step 2: Write ReadDesire                                            #
    # ------------------------------------------------------------------ #
    log("Step 2: Writing ReadDesire to specs table...")
    read_item = read_desire_item(read_doc_id, cluster_name, args.namespace, cm_name)
    t0 = time.monotonic()
    ddb.put_item(TableName=tbl_specs_read, Item=read_item)
    timings["write_read_desire_ms"] = (time.monotonic() - t0) * 1000
    ok(f"ReadDesire written   (+{timings['write_read_desire_ms']:.0f}ms)")
    print()

    # ------------------------------------------------------------------ #
    # Step 3: Verify both items landed                                    #
    # ------------------------------------------------------------------ #
    log("Step 3: Verifying desires landed in DynamoDB...")
    for tbl, doc_id, label in [
        (tbl_specs_apply, apply_doc_id, "ApplyDesire"),
        (tbl_specs_read, read_doc_id, "ReadDesire"),
    ]:
        resp = ddb.get_item(
            TableName=tbl, Key={"documentID": {"S": doc_id}}, ConsistentRead=True
        )
        if not resp.get("Item"):
            die(
                f"{label} not found in {tbl} immediately after write — something is wrong"
            )
        ok(f"  {label} verified in {tbl}")
    print()

    # ------------------------------------------------------------------ #
    # Step 4: Poll ApplyDesire status (kube-applier applies ConfigMap)    #
    # ------------------------------------------------------------------ #
    log(
        f"Step 4: Polling status-applydesires for Successful=True (timeout={args.timeout}s)..."
    )
    step4_start = time.monotonic()
    apply_ms = poll_apply_status(
        ddb,
        tbl_status_apply,
        apply_doc_id,
        None,  # no staleness check for create — any Successful=True is fine
        args.timeout,
        args.poll_interval,
        step4_start,
    )
    if apply_ms is None:
        warn(f"Timed out waiting for ApplyDesire Successful=True after {args.timeout}s")
        timings["apply_desire_confirmed_ms"] = None
    else:
        timings["apply_desire_confirmed_ms"] = apply_ms
        ok(
            f"ApplyDesire confirmed Successful=True  (+{apply_ms:.0f}ms from poll start)"
        )
    print()

    # ------------------------------------------------------------------ #
    # Step 5: Poll ReadDesire status (kube-applier mirrors ConfigMap)     #
    # ------------------------------------------------------------------ #
    log(
        f"Step 5: Polling status-readdesires for kubeContent (timeout={args.timeout}s)..."
    )
    step5_start = time.monotonic()
    read_ms = poll_read_status(
        ddb,
        tbl_status_read,
        read_doc_id,
        args.timeout,
        args.poll_interval,
        step5_start,
    )
    if read_ms is None:
        warn(
            f"Timed out waiting for ReadDesire status_kubeContent after {args.timeout}s"
        )
        timings["read_desire_status_ms"] = None
    else:
        timings["read_desire_status_ms"] = read_ms
        ok(
            f"ReadDesire status_kubeContent populated (+{read_ms:.0f}ms from poll start)"
        )

        # Show what came back
        resp = ddb.get_item(
            TableName=tbl_status_read,
            Key={"documentID": {"S": read_doc_id}},
            ConsistentRead=True,
        )
        kube_content_raw = (
            resp.get("Item", {}).get("status_kubeContent", {}).get("S", "")
        )
        if kube_content_raw:
            try:
                print(json.dumps(json.loads(kube_content_raw), indent=2)[:800])
            except Exception:
                print(kube_content_raw[:400])
    print()

    # ------------------------------------------------------------------ #
    # Step 6: Flip ApplyDesire to Type=Delete                             #
    # ------------------------------------------------------------------ #
    log("Step 6: Flipping ApplyDesire to Type=Delete...")
    resp = ddb.get_item(
        TableName=tbl_specs_apply,
        Key={"documentID": {"S": apply_doc_id}},
        ConsistentRead=True,
    )
    if not resp.get("Item"):
        warn("ApplyDesire spec item not found — may have been cleaned up already")
    else:
        delete_item = apply_desire_delete_item(resp["Item"])
        t0 = time.monotonic()
        ddb.put_item(TableName=tbl_specs_apply, Item=delete_item)
        timings["write_delete_desire_ms"] = (time.monotonic() - t0) * 1000
        ok(f"Delete desire written (+{timings['write_delete_desire_ms']:.0f}ms)")
    print()

    # ------------------------------------------------------------------ #
    # Step 7: Poll ApplyDesire status for delete confirmation             #
    # ------------------------------------------------------------------ #
    log(
        f"Step 7: Polling status-applydesires for delete Successful=True (timeout={args.timeout}s)..."
    )
    if not resp.get("Item"):
        warn("Skipping delete poll — spec item was not found in Step 6")
        timings["delete_desire_confirmed_ms"] = None
    else:
        step7_start = time.monotonic()
        delete_update_time = delete_item["updateTime"]["S"]
        delete_ms = poll_apply_status(
            ddb,
            tbl_status_apply,
            apply_doc_id,
            delete_update_time,  # gate: observedDesireUpdateTime must be >= this
            args.timeout,
            args.poll_interval,
            step7_start,
        )
        if delete_ms is None:
            warn(f"Timed out waiting for delete Successful=True after {args.timeout}s")
            timings["delete_desire_confirmed_ms"] = None
        else:
            timings["delete_desire_confirmed_ms"] = delete_ms
            ok(f"Delete confirmed Successful=True (+{delete_ms:.0f}ms from poll start)")
    print()

    # ------------------------------------------------------------------ #
    # Step 8: Cleanup — remove desires from specs tables                  #
    # ------------------------------------------------------------------ #
    if args.no_cleanup:
        warn("Skipping cleanup (--no-cleanup). Desires left in DynamoDB.")
    else:
        log("Step 8: Cleaning up — deleting desires from specs tables...")
        for tbl, doc_id, label in [
            (tbl_specs_apply, apply_doc_id, "ApplyDesire"),
            (tbl_specs_read, read_doc_id, "ReadDesire"),
        ]:
            ddb.delete_item(TableName=tbl, Key={"documentID": {"S": doc_id}})
            ok(f"  Deleted {label} from {tbl}")
    print()

    # ------------------------------------------------------------------ #
    # Summary                                                             #
    # ------------------------------------------------------------------ #
    total_ms = (time.monotonic() - overall_start) * 1000

    def fmt(v):
        return f"{v:.0f}ms" if v is not None else "TIMED OUT"

    print("━" * 52)
    print(" Timing Summary")
    print("━" * 52)
    print(f"  Env ID                        : {env_id}")
    print(f"  MC cluster name               : {cluster_name}")
    print(f"  ConfigMap                     : {args.namespace}/{cm_name}")
    print()
    print(
        f"  Write ApplyDesire             : {fmt(timings.get('write_apply_desire_ms'))}"
    )
    print(
        f"  Write ReadDesire              : {fmt(timings.get('write_read_desire_ms'))}"
    )
    print(
        f"  Apply confirmed (SSA→True)    : {fmt(timings.get('apply_desire_confirmed_ms'))}"
    )
    print(
        f"  Read status populated         : {fmt(timings.get('read_desire_status_ms'))}"
    )
    print(
        f"  Write delete desire           : {fmt(timings.get('write_delete_desire_ms'))}"
    )
    print(
        f"  Delete confirmed (Del→True)   : {fmt(timings.get('delete_desire_confirmed_ms'))}"
    )
    print()
    print(
        f"  Total wall time               : {total_ms:.0f}ms ({total_ms / 1000:.1f}s)"
    )
    print("━" * 52)


if __name__ == "__main__":
    main()
