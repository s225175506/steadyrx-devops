#!/usr/bin/env bash
# Writes release notes and a release manifest for the promoted version.
set -euo pipefail
VERSION="${1:?}"
IMAGE_TAG="${2:?}"
REGISTRY="${REGISTRY:-localhost:5000}"
export DOCKER_HOST="${DOCKER_HOST:-unix://${HOME}/.colima/default/docker.sock}"

mkdir -p reports
LAST_TAG="$(git describe --tags --abbrev=0 HEAD~1 2>/dev/null || true)"
if [[ -n "$LAST_TAG" ]]; then
  RANGE="${LAST_TAG}..HEAD"
else
  RANGE="HEAD"
fi
COMMITS="$(git log "$RANGE" --pretty=format:'- %h %s (%an)' -n 20 2>/dev/null || true)"
DIGEST="$(docker inspect --format '{{index .RepoDigests 0}}' "${REGISTRY}/steadyrx-api:v${VERSION}" 2>/dev/null || echo '')"

SINCE="${LAST_TAG:-the first release}"
cat > reports/release-notes.md <<EOF
# SteadyRx API release v${VERSION}

* Image: ${REGISTRY}/steadyrx-api:v${VERSION} (also tagged stable)
* Built from: ${IMAGE_TAG}
* Digest: ${DIGEST}
* Jenkins build: ${BUILD_URL:-local}
* Promoted from staging after unit, integration, quality gate, security and staging smoke tests passed.

## Changes since ${SINCE}
${COMMITS}
EOF

python3 - <<PY
import json
from datetime import datetime
print(json.dumps({
  "version": "${VERSION}",
  "image": "${REGISTRY}/steadyrx-api:v${VERSION}",
  "source_tag": "${IMAGE_TAG}",
  "digest": """${DIGEST}""",
  "released_at": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S"),
  "environment": "production",
}, indent=2))
PY
> reports/release-manifest.json

# rewrite manifest properly
python3 - <<PY
import json
from datetime import datetime
from pathlib import Path
Path("reports/release-manifest.json").write_text(json.dumps({
  "version": "${VERSION}",
  "image": "${REGISTRY}/steadyrx-api:v${VERSION}",
  "source_tag": "${IMAGE_TAG}",
  "digest": """${DIGEST}""",
  "released_at": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S"),
  "environment": "production",
}, indent=2))
PY

cat reports/release-notes.md
