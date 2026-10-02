#!/usr/bin/env bash
# Source and dependency security scans run inside the test image.
set -euo pipefail
mkdir -p reports

echo "== Bandit SAST: full report of every severity"
bandit -r app -f json -o reports/bandit.json --exit-zero
bandit -r app -f txt --exit-zero | tee reports/bandit.txt
echo "== Bandit gate: fail on MEDIUM or HIGH severity with MEDIUM or HIGH confidence"
bandit -r app -ll -ii -q

echo "== pip-audit: known CVEs in pinned runtime dependencies"
pip-audit -r requirements.txt --desc on -f json -o reports/pip-audit.json || true
pip-audit -r requirements.txt --desc on
