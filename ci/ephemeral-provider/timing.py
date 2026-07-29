"""Lightweight phase-timing instrumentation for CI pipelines.

Records phase start/end times to a JSONL file in $SHARED_DIR so that a
timing report can be generated at the end of the pipeline. Falls back
gracefully when SHARED_DIR is unset (local dev runs).
"""

import json
import logging
import os
import time
from contextlib import contextmanager
from pathlib import Path

log = logging.getLogger(__name__)

TIMING_FILENAME = "timing.jsonl"


def _timing_path() -> Path | None:
    shared = os.environ.get("SHARED_DIR")
    if not shared:
        return None
    return Path(shared) / TIMING_FILENAME


@contextmanager
def timed(phase: str, step: str):
    """Context manager that records a phase's wall-clock duration to timing.jsonl.

    Usage:
        with timed("wait-for-pipelines", "provision"):
            do_work()
    """
    path = _timing_path()
    start = time.time()
    status = "ok"
    try:
        yield
    except Exception:
        status = "error"
        raise
    finally:
        end = time.time()
        if path:
            record = {
                "phase": phase,
                "start": start,
                "end": end,
                "step": step,
                "status": status,
            }
            try:
                with open(path, "a") as f:
                    f.write(json.dumps(record) + "\n")
            except OSError as e:
                log.warning("Failed to write timing record: %s", e)
