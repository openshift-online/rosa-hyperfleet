#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
"""Generate a self-contained HTML timing report from a JSONL timing file.

Usage:
    uv run ci/timing-report.py <timing.jsonl> <output.html>

Each line in the JSONL file is a JSON object with:
    {"phase": "...", "start": epoch, "end": epoch, "step": "provision|e2e|teardown", "status": "ok|error"}
"""

import json
import sys
from pathlib import Path

STEP_ORDER = {"provision": 0, "e2e": 1, "teardown": 2}
STEP_COLORS = {
    "provision": "#388bfd",
    "e2e": "#56d364",
    "teardown": "#f0883e",
}
ERROR_COLOR = "#f85149"


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <timing.jsonl> <output.html>", file=sys.stderr)
        sys.exit(1)

    timing_file = Path(sys.argv[1])
    output_file = Path(sys.argv[2])

    records = []
    for line in timing_file.read_text().strip().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

    if not records:
        print("No timing records found.", file=sys.stderr)
        sys.exit(0)

    records.sort(key=lambda r: (STEP_ORDER.get(r.get("step", ""), 99), r.get("start", 0)))

    labels = []
    durations = []
    colors = []
    total_start = min(r["start"] for r in records)
    total_end = max(r["end"] for r in records)
    total_mins = (total_end - total_start) / 60

    for r in records:
        phase = r["phase"]
        step = r.get("step", "")
        duration_m = (r["end"] - r["start"]) / 60
        status = r.get("status", "ok")

        labels.append(f"{phase} ({step})")
        durations.append(round(duration_m, 1))
        colors.append(ERROR_COLOR if status == "error" else STEP_COLORS.get(step, "#8b949e"))

    labels_json = json.dumps(labels)
    durations_json = json.dumps(durations)
    colors_json = json.dumps(colors)

    html = f"""\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>CI Timing Report</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.4"></script>
<style>
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
         background: #0d1117; color: #c9d1d9; padding: 24px; }}
  h1 {{ font-size: 1.4rem; margin-bottom: 4px; }}
  .subtitle {{ color: #8b949e; font-size: 0.9rem; margin-bottom: 24px; }}
  .chart-container {{ background: #161b22; border: 1px solid #30363d;
                      border-radius: 8px; padding: 24px; margin-bottom: 24px; }}
  canvas {{ max-height: 600px; }}
  .legend {{ display: flex; gap: 24px; margin-top: 16px; flex-wrap: wrap; }}
  .legend-item {{ display: flex; align-items: center; gap: 6px; font-size: 0.85rem; }}
  .legend-swatch {{ width: 14px; height: 14px; border-radius: 3px; }}
</style>
</head>
<body>

<h1>CI Timing Report</h1>
<p class="subtitle">Total wall-clock: {total_mins:.1f} minutes</p>

<div class="chart-container">
  <canvas id="chart"></canvas>
  <div class="legend">
    <div class="legend-item"><div class="legend-swatch" style="background:{STEP_COLORS['provision']}"></div> Provision</div>
    <div class="legend-item"><div class="legend-swatch" style="background:{STEP_COLORS['e2e']}"></div> E2E Tests</div>
    <div class="legend-item"><div class="legend-swatch" style="background:{STEP_COLORS['teardown']}"></div> Teardown</div>
    <div class="legend-item"><div class="legend-swatch" style="background:{ERROR_COLOR}"></div> Error</div>
  </div>
</div>

<script>
new Chart(document.getElementById('chart'), {{
  type: 'bar',
  data: {{
    labels: {labels_json},
    datasets: [{{
      data: {durations_json},
      backgroundColor: {colors_json},
      borderRadius: 3,
    }}]
  }},
  options: {{
    indexAxis: 'y',
    responsive: true,
    plugins: {{
      legend: {{ display: false }},
      tooltip: {{ callbacks: {{ label: ctx => ctx.raw.toFixed(1) + 'm' }} }}
    }},
    scales: {{
      x: {{
        title: {{ display: true, text: 'Minutes', color: '#8b949e' }},
        ticks: {{ color: '#8b949e' }},
        grid: {{ color: '#21262d' }}
      }},
      y: {{
        ticks: {{ color: '#c9d1d9', font: {{ size: 12 }} }},
        grid: {{ display: false }}
      }}
    }}
  }}
}});
</script>
</body>
</html>"""

    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(html)
    print(f"Timing report written to {output_file}")


if __name__ == "__main__":
    main()
