#!/usr/bin/env bash
# Deploys one image tag to staging or production with Docker Compose.
# Failed health checks roll back to the previous healthy tag.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

ENVIRONMENT="${1:?usage: deploy.sh <staging|production> <image-tag> [expected-version]}"
IMAGE_TAG="${2:?}"
EXPECTED_VERSION="${3:-}"
REGISTRY="${REGISTRY:-localhost:5000}"
export DOCKER_HOST="${DOCKER_HOST:-unix://${HOME}/.colima/default/docker.sock}"

case "$ENVIRONMENT" in
  staging|production) ;;
  *) echo "Environment must be staging or production" >&2; exit 1 ;;
esac

ENV_FILE="$REPO_ROOT/deploy/config/${ENVIRONMENT}.env"
COMPOSE="$REPO_ROOT/deploy/docker-compose.app.yml"
PORT="$(read_env_var "$ENV_FILE" HOST_PORT)"
STATE_DIR="$(state_dir)"
TAG_FILE="$STATE_DIR/${ENVIRONMENT}.tag"
SECRET_FILE="$STATE_DIR/${ENVIRONMENT}.jwt"
HISTORY_FILE="$STATE_DIR/${ENVIRONMENT}-history.log"

if [[ ! -f "$SECRET_FILE" ]]; then
  openssl rand -base64 48 | tr -d '\n' > "$SECRET_FILE"
  echo "Generated a new JWT signing key for $ENVIRONMENT"
fi

PREVIOUS=""
if [[ -f "$TAG_FILE" ]]; then
  PREVIOUS="$(tr -d '[:space:]' < "$TAG_FILE")"
fi

start_release() {
  local tag="$1"
  export IMAGE_TAG="$tag"
  export REGISTRY
  export DEPLOY_ENV="$ENVIRONMENT"
  export HOST_PORT="$PORT"
  export JWT_SECRET
  JWT_SECRET="$(tr -d '[:space:]' < "$SECRET_FILE")"
  docker compose -p "steadyrx-${ENVIRONMENT}" --env-file "$ENV_FILE" -f "$COMPOSE" pull --quiet || true
  docker compose -p "steadyrx-${ENVIRONMENT}" --env-file "$ENV_FILE" -f "$COMPOSE" up -d --remove-orphans
}

echo "Deploying ${REGISTRY}/steadyrx-api:${IMAGE_TAG} to ${ENVIRONMENT} (port ${PORT}). Previous: ${PREVIOUS:-none}"
start_release "$IMAGE_TAG"

if wait_healthy "http://127.0.0.1:${PORT}" "$EXPECTED_VERSION"; then
  printf '%s' "$IMAGE_TAG" > "$TAG_FILE"
  echo "$(date -u +%Y-%m-%dT%H:%M:%S) deployed $IMAGE_TAG" >> "$HISTORY_FILE"
  echo "Deployment of $IMAGE_TAG to $ENVIRONMENT succeeded"
  exit 0
fi

echo "Health check failed for $IMAGE_TAG in $ENVIRONMENT"
docker logs --tail 50 "steadyrx-${ENVIRONMENT}" 2>&1 || true
if [[ -n "$PREVIOUS" && "$PREVIOUS" != "$IMAGE_TAG" ]]; then
  echo "Rolling $ENVIRONMENT back to $PREVIOUS"
  start_release "$PREVIOUS"
  if wait_healthy "http://127.0.0.1:${PORT}"; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%S) rollback to $PREVIOUS after $IMAGE_TAG failed" >> "$HISTORY_FILE"
    echo "Rollback to $PREVIOUS succeeded"
  fi
fi
exit 1
