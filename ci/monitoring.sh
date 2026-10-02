#!/usr/bin/env bash
# Starts or refreshes the monitoring stack and proves it is watching production.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
export DOCKER_HOST="${DOCKER_HOST:-unix://${HOME}/.colima/default/docker.sock}"

COMPOSE="$REPO_ROOT/monitoring/docker-compose.yml"
docker compose -p steadyrx-monitoring -f "$COMPOSE" up -d --build --remove-orphans

wait_http Prometheus 'http://127.0.0.1:9090/-/ready'
wait_http Alertmanager 'http://127.0.0.1:9093/-/ready'
wait_http Grafana 'http://127.0.0.1:3000/api/health'
wait_http 'Alert receiver' 'http://127.0.0.1:9095/health'

curl -sf -X POST 'http://127.0.0.1:9090/-/reload' >/dev/null || true
curl -sf -X POST 'http://127.0.0.1:9093/-/reload' >/dev/null || true

prod_up=false
for i in $(seq 1 20); do
  if curl -sf 'http://127.0.0.1:9090/api/v1/targets' \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); ts=d.get("data",{}).get("activeTargets",[]);
print("yes" if any(t.get("labels",{}).get("job")=="steadyrx-production" and t.get("health")=="up" for t in ts) else "no")' \
    | grep -q yes; then
    prod_up=true
    break
  fi
  sleep 3
done
if [[ "$prod_up" != true ]]; then
  echo "Prometheus cannot scrape the production API" >&2
  exit 1
fi
echo "Prometheus is scraping steadyrx-production (health=up)"

python3 - <<'PY'
import json, urllib.request, urllib.parse
from pathlib import Path
from datetime import datetime

rules = json.load(urllib.request.urlopen("http://127.0.0.1:9090/api/v1/rules"))
names = []
for g in rules.get("data", {}).get("groups", []):
    for r in g.get("rules", []):
        if name := r.get("name"):
            names.append(name)
print(f"Alert rules loaded ({len(names)}): {', '.join(names)}")
if len(names) < 5:
    raise SystemExit("Expected at least five alert rules")
q = urllib.parse.quote('sum(rate(steadyrx_http_requests_total{job="steadyrx-production"}[1m]))')
rps = json.load(urllib.request.urlopen(f"http://127.0.0.1:9090/api/v1/query?query={q}"))
summary = {
    "checked_at": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S"),
    "production_target": "up",
    "alert_rules": names,
    "production_request_rate": rps.get("data", {}).get("result"),
    "grafana": "http://localhost:3000/d/steadyrx",
    "prometheus": "http://localhost:9090/alerts",
    "alert_channel": "http://localhost:9095/",
}
out = Path("reports")
out.mkdir(exist_ok=True)
(out / "monitoring-summary.json").write_text(json.dumps(summary, indent=2))
print("Monitoring stack verified. Dashboard: http://localhost:3000/d/steadyrx")
PY
