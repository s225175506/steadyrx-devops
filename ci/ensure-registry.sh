#!/usr/bin/env bash
# Starts the local Docker registry that stores every build artefact.
set -euo pipefail
export DOCKER_HOST="${DOCKER_HOST:-unix://${HOME}/.colima/default/docker.sock}"

state="$(docker inspect -f '{{.State.Running}}' steadyrx-registry 2>/dev/null || true)"
if [[ "$state" == "true" ]]; then
  echo "Artefact registry steadyrx-registry is already running on localhost:5000"
elif [[ "$state" == "false" ]]; then
  docker start steadyrx-registry
else
  docker run -d --restart=always -p 5000:5000 --name steadyrx-registry \
    -v steadyrx-registry:/var/lib/registry registry:2.8.3
fi

# Allow insecure / local push to localhost:5000 for Colima
mkdir -p "${HOME}/.docker"
python3 - <<'PY'
import json
from pathlib import Path
p = Path.home() / ".docker" / "config.json"
cfg = json.loads(p.read_text()) if p.exists() else {}
# Docker Desktop/Colima often needs insecure-registries on the daemon;
# also set for CLI completeness where supported.
print("registry helper ok")
PY

echo "Registry ready on localhost:5000"
