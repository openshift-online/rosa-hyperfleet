#!/usr/bin/env python3
"""Collects CI job health, open PRs, and recently merged PRs for the IC briefing.

Outputs a single JSON object to stdout. Diagnostic messages go to stderr.
"""

import json
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from urllib.request import urlopen

REPO = "openshift-online/rosa-hyperfleet"
GCS_BUCKET = "https://storage.googleapis.com/test-platform-results"
BUILD_COUNT = 10

PERIODIC_JOBS = [
    "periodic-ci-openshift-online-rosa-hyperfleet-main-nightly-ephemeral",
    "periodic-ci-openshift-online-rosa-hyperfleet-main-nightly-integration",
]
PR_JOB = "pull-ci-openshift-online-rosa-hyperfleet-main-on-demand-e2e"


def log(msg):
    print(msg, file=sys.stderr)


def gcs_fetch(path):
    try:
        with urlopen(f"{GCS_BUCKET}/{path}", timeout=15) as resp:
            return resp.read().decode()
    except Exception:
        return None


def gcs_list_xml(prefix):
    raw = gcs_fetch(f"?prefix={prefix}&delimiter=/")
    if not raw:
        return [], []
    root = ET.fromstring(raw)
    ns = root.tag.split("}")[0] + "}" if "}" in root.tag else ""
    prefixes = [
        elem.text
        for elem in root.iter(f"{ns}Prefix")
        if elem.text and elem.text.count("/") > 2
    ]
    keys = [elem.text for elem in root.iter(f"{ns}Key") if elem.text]
    return prefixes, keys


def fetch_finished(path):
    raw = gcs_fetch(f"{path}/finished.json")
    if not raw:
        return {"result": "UNKNOWN", "timestamp": 0}
    try:
        data = json.loads(raw)
        return {
            "result": data.get("result", "UNKNOWN"),
            "timestamp": data.get("timestamp", 0),
        }
    except json.JSONDecodeError:
        return {"result": "UNKNOWN", "timestamp": 0}


def collect_periodic_job(job_name):
    log(f"Collecting {job_name}...")
    prefixes, _ = gcs_list_xml(f"logs/{job_name}/")
    build_ids = sorted(
        [p.rstrip("/").split("/")[-1] for p in prefixes], reverse=True
    )[:BUILD_COUNT]

    results = []
    for bid in build_ids:
        finished = fetch_finished(f"logs/{job_name}/{bid}")
        results.append({"build_id": bid, **finished})
    return job_name, results


def collect_pr_job():
    log(f"Collecting {PR_JOB}...")
    _, keys = gcs_list_xml(f"pr-logs/directory/{PR_JOB}/")
    build_ids = sorted(
        [
            k.split("/")[-1].replace(".txt", "")
            for k in keys
            if k.endswith(".txt") and "latest" not in k
        ],
        reverse=True,
    )[:BUILD_COUNT]

    results = []
    for bid in build_ids:
        raw_path = gcs_fetch(f"pr-logs/directory/{PR_JOB}/{bid}.txt")
        if not raw_path:
            continue
        path = raw_path.strip().replace("gs://test-platform-results/", "")

        pr_number = "unknown"
        parts = path.split("/")
        for i, part in enumerate(parts):
            if part == "rosa-hyperfleet" and i + 1 < len(parts):
                pr_number = parts[i + 1]
                break

        finished = fetch_finished(path)
        results.append({"build_id": bid, "pr_number": pr_number, **finished})

    return PR_JOB, results


def collect_open_prs():
    log("Collecting open PRs...")
    result = subprocess.run(
        [
            "gh", "pr", "list",
            "--repo", REPO,
            "--state", "open",
            "--json", "number,title,body,author,labels,reviewRequests,createdAt,updatedAt,isDraft",
            "--limit", "50",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def collect_recently_merged_prs():
    log("Collecting recently merged PRs (last 7 days)...")
    since = (datetime.now(timezone.utc) - timedelta(days=7)).strftime("%Y-%m-%d")
    result = subprocess.run(
        [
            "gh", "pr", "list",
            "--repo", REPO,
            "--state", "merged",
            "--json", "number,title,body,author,mergedAt,labels",
            "--limit", "30",
            "--search", f"merged:>={since}",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def main():
    log("=== IC Data Collection ===\n")

    ci_jobs = {}
    open_prs = []
    merged_prs = []

    with ThreadPoolExecutor(max_workers=6) as pool:
        futures = {}
        for job in PERIODIC_JOBS:
            futures[pool.submit(collect_periodic_job, job)] = "periodic"
        futures[pool.submit(collect_pr_job)] = "pr_job"
        futures[pool.submit(collect_open_prs)] = "open_prs"
        futures[pool.submit(collect_recently_merged_prs)] = "merged_prs"

        for future in as_completed(futures):
            kind = futures[future]
            try:
                result = future.result()
            except Exception as exc:
                log(f"Error collecting {kind}: {exc}")
                continue

            if kind == "periodic":
                job_name, builds = result
                ci_jobs[job_name] = builds
            elif kind == "pr_job":
                job_name, builds = result
                ci_jobs[job_name] = builds
            elif kind == "open_prs":
                open_prs = result
            elif kind == "merged_prs":
                merged_prs = result

    log("\n=== Collection complete ===")

    output = {
        "timestamp": int(time.time()),
        "ci_jobs": ci_jobs,
        "open_prs": open_prs,
        "recently_merged_prs": merged_prs,
    }
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
