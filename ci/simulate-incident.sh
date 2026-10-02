#!/usr/bin/env bash
# Incident drill against production monitoring.
#   brute-force : 25 failed logins -> SteadyRxLoginFailureSpike
#   api-down    : stop production container -> SteadyRxApiDown, then recover
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
export DOCKER_HOST="${DOCKER_HOST:-unix://${HOME}/.colima/default/docker.sock}"

SCENARIO="${1:-brute-force}"
TIMEOUT_SECONDS="${2:-150}"
PROD="http://127.0.0.1:8000"
RECEIVER="http://127.0.0.1:9095/alerts"

epoch() { python3 -c 'import time; print(time.time())'; }

wait_alert() {
  local name="$1" status="$2" since="$3"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if hit="$(curl -sf "$RECEIVER" 2>/dev/null | python3 -c "
import json,sys
name='$name'; status='$status'; since=float('$since')
try:
  events=json.load(sys.stdin)
except Exception:
  events=[]
if not isinstance(events, list):
  events=[events]
for e in events:
  if e.get('alertname')==name and e.get('status')==status and float(e.get('received_epoch',0))>=since:
    print(json.dumps(e)); break
")"; then
      if [[ -n "$hit" ]]; then
        echo "$hit"
        return 0
      fi
    fi
    sleep 3
  done
  return 1
}

START="$(epoch)"
if [[ "$SCENARIO" == "brute-force" ]]; then
  ALERT_NAME="SteadyRxLoginFailureSpike"
  echo "Simulating a password guessing attack with 25 failed logins"
  for i in $(seq 1 25); do
    curl -sf -X POST "$PROD/api/v1/auth/login" \
      -H 'Content-Type: application/json' \
      -d "{\"username\":\"daniel\",\"password\":\"guess$i\"}" >/dev/null 2>&1 || true
  done
else
  ALERT_NAME="SteadyRxApiDown"
  echo "Simulating an outage by stopping the production container"
  docker stop steadyrx-production
fi

if ! FIRED="$(wait_alert "$ALERT_NAME" firing "$START")"; then
  if [[ "$SCENARIO" == "api-down" ]]; then
    docker start steadyrx-production || true
  fi
  echo "$ALERT_NAME was not delivered within ${TIMEOUT_SECONDS}s" >&2
  exit 1
fi

TTD="$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); print(round(float(e['received_epoch'])-float(sys.argv[2]),1))" "$FIRED" "$START")"
SEV="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('severity',''))" "$FIRED")"
SUM="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('summary',''))" "$FIRED")"
echo "ALERT DELIVERED: $ALERT_NAME ($SEV) in ${TTD}s - $SUM"

RESULT_FILE="reports/incident-${SCENARIO}.json"
mkdir -p reports
python3 - <<PY
import json
from pathlib import Path
result={"scenario":"${SCENARIO}","alert":"${ALERT_NAME}","time_to_detect_seconds":float("${TTD}")}
Path("${RESULT_FILE}").write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
PY

if [[ "$SCENARIO" == "api-down" ]]; then
  RECOVER="$(epoch)"
  docker start steadyrx-production
  if ! wait_healthy "$PROD"; then
    echo "Production did not recover after the drill" >&2
    exit 1
  fi
  if RESOLVED="$(wait_alert "$ALERT_NAME" resolved "$RECOVER")"; then
    TTR="$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); print(round(float(e['received_epoch'])-float(sys.argv[2]),1))" "$RESOLVED" "$RECOVER")"
    python3 - <<PY
import json
from pathlib import Path
p=Path("${RESULT_FILE}")
d=json.loads(p.read_text())
d["time_to_resolve_seconds"]=float("${TTR}")
p.write_text(json.dumps(d, indent=2))
print(f"RESOLVED notification received after {d['time_to_resolve_seconds']} s")
PY
  fi
fi
