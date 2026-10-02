#!/usr/bin/env bash
# Prepares Docker for the Mac Jenkins agent (Colima).
set -euo pipefail

export DOCKER_HOST="${DOCKER_HOST:-unix://${HOME}/.colima/default/docker.sock}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker CLI not found on PATH" >&2
  exit 1
fi

if command -v colima >/dev/null 2>&1; then
  if ! colima status 2>/dev/null | grep -qi 'running'; then
    echo "Starting Colima..."
    colima start --cpu 2 --memory 4 || true
  fi
  docker context use colima >/dev/null 2>&1 || true
fi

# Compose / buildx plugin path (Homebrew). Prefer classic builder if buildx is absent.
mkdir -p "${HOME}/.docker/cli-plugins"
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

# Symlink Homebrew compose/buildx plugins into ~/.docker/cli-plugins when present
for plugin in docker-compose docker-buildx; do
  src="/opt/homebrew/lib/docker/cli-plugins/${plugin}"
  dst="${HOME}/.docker/cli-plugins/${plugin}"
  if [[ -x "$src" && ! -e "$dst" ]]; then
    ln -sf "$src" "$dst"
  fi
done

# Avoid BuildKit when buildx is missing (Colima default)
if ! docker buildx version >/dev/null 2>&1; then
  export DOCKER_BUILDKIT=0
  echo "buildx not found — using classic builder (DOCKER_BUILDKIT=0)"
fi

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
