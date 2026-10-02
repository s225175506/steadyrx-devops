#!/usr/bin/env bash
# Prepares Docker for the Mac Jenkins agent (Colima).
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

export DOCKER_HOST="${DOCKER_HOST:-unix://${HOME}/.colima/default/docker.sock}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker CLI not found on PATH" >&2
  exit 1
fi

# Ensure Colima is up when available (with local insecure registry for artefacts)
if command -v colima >/dev/null 2>&1; then
  if ! colima status 2>/dev/null | grep -qi 'running'; then
    echo "Starting Colima..."
    colima start --cpu 2 --memory 4 --insecure-registry localhost:5000 || colima start --cpu 2 --memory 4 || true
  fi
  docker context use colima >/dev/null 2>&1 || true
fi

# Compose plugin path (Homebrew)
mkdir -p "${HOME}/.docker"
python3 - <<'PY'
import json
from pathlib import Path
p = Path.home() / ".docker" / "config.json"
cfg = json.loads(p.read_text()) if p.exists() else {}
dirs = cfg.get("cliPluginsExtraDirs") or []
want = "/opt/homebrew/lib/docker/cli-plugins"
if want not in dirs:
    dirs.append(want)
cfg["cliPluginsExtraDirs"] = dirs
p.write_text(json.dumps(cfg, indent=2) + "\n")
PY

ready=false
for i in $(seq 1 20); do
  if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    ready=true
    break
  fi
  echo "Waiting for the Docker engine..."
  sleep 3
done
if [[ "$ready" != true ]]; then
  echo "Docker engine is not reachable. Start Colima / Docker and rerun." >&2
  exit 1
fi

docker version --format 'Docker engine {{.Server.Version}} ({{.Server.Os}}/{{.Server.Arch}})'
docker compose version
echo "Docker ready"
