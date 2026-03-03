#!/usr/bin/env python3
"""Summarize one BountyBench native run directory produced by run_parallel.sh."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any

DATE_FMT = "%a %b %d %H:%M:%S %Z %Y"


def _parse_meta(meta_path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    for raw_line in meta_path.read_text().splitlines():
        line = raw_line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def _load_json(path: Path) -> dict[str, Any] | None:
    if not path.exists() or not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None


def _workflow_fields(workflow_json_path: Path | None) -> dict[str, Any]:
    if workflow_json_path is None:
        return {
            "phase_summary": "unknown",
            "phase_submit": None,
            "phase_success": None,
            "phase_max_iterations": None,
            "workflow_success": None,
        }

    payload = _load_json(workflow_json_path)
    if payload is None:
        return {
            "phase_summary": "unknown",
            "phase_submit": None,
            "phase_success": None,
            "phase_max_iterations": None,
            "workflow_success": None,
        }

    phase_messages = payload.get("phase_messages") or []
    last_phase = phase_messages[-1] if phase_messages else {}
    workflow_success = (
        payload.get("workflow_metadata", {})
        .get("workflow_summary", {})
        .get("success")
    )

    return {
        "phase_summary": last_phase.get("phase_summary", "unknown"),
        "phase_submit": last_phase.get("submit"),
        "phase_success": last_phase.get("success"),
        "phase_max_iterations": last_phase.get("max_iterations"),
        "workflow_success": workflow_success,
    }


def _parse_dt(value: str) -> datetime | None:
    try:
        return datetime.strptime(value, DATE_FMT)
    except ValueError:
        return None


def _parse_run_window(results_log_path: Path) -> tuple[str | None, str | None, int | None]:
    if not results_log_path.exists():
        return None, None, None

    start_str: str | None = None
    finish_str: str | None = None

    first_line = results_log_path.read_text().splitlines()[:1]
    if first_line:
        m = re.search(r"—\s*(.+?)\s*=+$", first_line[0])
        if m:
            start_str = m.group(1).strip()

    for line in results_log_path.read_text().splitlines():
        if line.startswith("Finished at "):
            finish_str = line.replace("Finished at ", "", 1).strip()
            break

    wall_seconds: int | None = None
    if start_str and finish_str:
        start_dt = _parse_dt(start_str)
        finish_dt = _parse_dt(finish_str)
        if start_dt and finish_dt:
            wall_seconds = int((finish_dt - start_dt).total_seconds())

    return start_str, finish_str, wall_seconds


def _classify(task: dict[str, Any]) -> str:
    status = task["status"]
    phase_summary = str(task.get("phase_summary") or "")
    if status == "PASS":
        return "pass"
    if status == "TIMEOUT":
        return "timeout"
    if status == "BROKEN":
        return "broken"
    if phase_summary.startswith("no_submission/"):
        return "no_submission"
    if phase_summary.startswith("receive_submission/"):
        return "submitted_but_failed"
    if status == "OK":
        return "ok_other"
    return "unknown"


def summarize_run(run_dir: Path) -> dict[str, Any]:
    native_logs_dir = run_dir / "native_logs"
    results_log_path = run_dir / "results.log"

    tasks: list[dict[str, Any]] = []
    for meta_path in sorted(native_logs_dir.glob("*/meta.txt")):
        meta = _parse_meta(meta_path)
        task_name = meta.get("task", "unknown")
        status = meta.get("status", "unknown")
        elapsed = int(meta.get("elapsed_seconds", "0"))

        workflow_json_raw = meta.get("workflow_json")
        workflow_json_path = None
        if workflow_json_raw and workflow_json_raw != "none":
            workflow_json_path = Path(workflow_json_raw)

        wf = _workflow_fields(workflow_json_path)
        task = {
            "task": task_name,
            "status": status,
            "elapsed_seconds": elapsed,
            "exit_code": int(meta.get("exit_code", "-1")),
            "workflow_success": (
                wf["workflow_success"]
                if wf["workflow_success"] is not None
                else meta.get("workflow_success")
            ),
            "phase_summary": wf["phase_summary"],
            "phase_submit": wf["phase_submit"],
            "phase_success": wf["phase_success"],
            "phase_max_iterations": wf["phase_max_iterations"],
            "stdout_log": meta.get("stdout_log"),
            "workflow_json": str(workflow_json_path) if workflow_json_path else None,
        }
        task["classification"] = _classify(task)
        tasks.append(task)

    total = len(tasks)
    status_counts = Counter(t["status"] for t in tasks)
    class_counts = Counter(t["classification"] for t in tasks)
    pass_count = status_counts.get("PASS", 0)

    start_str, finish_str, wall_seconds = _parse_run_window(results_log_path)

    return {
        "run_dir": str(run_dir),
        "n_tasks": total,
        "status_counts": dict(status_counts),
        "classification_counts": dict(class_counts),
        "pass_count": pass_count,
        "pass_rate": (pass_count / total) if total else 0.0,
        "sum_elapsed_seconds": sum(t["elapsed_seconds"] for t in tasks),
        "run_started_at": start_str,
        "run_finished_at": finish_str,
        "wall_clock_seconds": wall_seconds,
        "tasks": tasks,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--run-dir",
        type=Path,
        required=True,
        help="Path to results_parallel/run_<timestamp>",
    )
    parser.add_argument(
        "--json-out",
        type=Path,
        default=None,
        help="Optional output path for machine-readable JSON summary",
    )
    args = parser.parse_args()

    summary = summarize_run(args.run_dir)
    if args.json_out:
        args.json_out.write_text(json.dumps(summary, indent=2))

    print(f"Run dir: {summary['run_dir']}")
    print(f"Tasks: {summary['n_tasks']}")
    print(
        "Statuses: "
        + ", ".join(f"{k}={v}" for k, v in sorted(summary["status_counts"].items()))
    )
    print(
        "Classifications: "
        + ", ".join(
            f"{k}={v}" for k, v in sorted(summary["classification_counts"].items())
        )
    )
    print(f"Pass: {summary['pass_count']}/{summary['n_tasks']} ({summary['pass_rate']:.1%})")
    print(f"Sum elapsed: {summary['sum_elapsed_seconds']}s")
    if summary["wall_clock_seconds"] is not None:
        print(f"Wall clock: {summary['wall_clock_seconds']}s")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
