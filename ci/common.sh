#!/usr/bin/env bash
# Shared helpers for the SteadyRx Mac / Colima Jenkins agent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

state_dir() {
  local base="${JENKINS_HOME:-$REPO_ROOT/.state}"
  local dir="$base/steadyrx-state"
  mkdir -p "$dir"
  echo "$dir"
}

read_env_var() {
  local file="$1" key="$2"
  grep -E "^${key}=" "$file" | head -1 | cut -d= -f2-
}

wait_healthy() {
  local base_url="$1"
  local expected_version="${2:-}"
  local timeout_seconds="${3:-90}"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    if ready="$(curl -sf --max-time 5 "$base_url/health/ready" 2>/dev/null)" \
       && ver="$(curl -sf --max-time 5 "$base_url/version" 2>/dev/null)"; then
      local db version env
      db="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("database", False))' <<<"$ready")"
      version="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' <<<"$ver")"
      env="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("environment",""))' <<<"$ver")"
      if [[ "$db" == "True" ]] && { [[ -z "$expected_version" ]] || [[ "$version" == "$expected_version" ]]; }; then
        echo "Healthy: $base_url is serving version $version in $env"
        return 0
      fi
      echo "Waiting: $base_url reports version $version"
    else
      echo "Waiting for $base_url ..."
    fi
    sleep 3
  done
  return 1
}

wait_http() {
  local name="$1" url="$2" attempts="${3:-30}"
  local i
  for ((i=0; i<attempts; i++)); do
    if curl -sf --max-time 3 "$url" >/dev/null 2>&1; then
      echo "$name is ready"
      return 0
    fi
    sleep 2
  done
  echo "$name did not become ready" >&2
  return 1
}
