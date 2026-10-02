#!/usr/bin/env bash
# Sends a pipeline event to the team alert channel.
set -euo pipefail
STATUS="${1:-FAILED}"
SUMMARY="${2:-}"
SEVERITY="${3:-critical}"

export STATUS SUMMARY SEVERITY
python3 - <<'PY' | curl -sf -X POST 'http://127.0.0.1:9095/alert' \
  -H 'Content-Type: application/json' \
  -d @- >/dev/null 2>&1 \
  && echo "Team notified" \
  || echo "Alert channel not reachable yet, notification skipped"
import json, os
status = os.environ.get("STATUS", "FAILED")
print(json.dumps({
  "alertname": "JenkinsPipeline" + status,
  "status": "firing" if status == "FAILED" else "info",
  "severity": os.environ.get("SEVERITY", "critical"),
  "team": "steadyrx",
  "summary": os.environ.get("SUMMARY", ""),
  "description": f"{os.environ.get('JOB_NAME','')} build {os.environ.get('BUILD_NUMBER','')} - {os.environ.get('BUILD_URL','')}",
}))
PY
