#!/usr/bin/env bash
# Code quality checks run inside the test image by the Code Quality stage.
# Each tool has an explicit threshold, so the stage fails on regressions.
set -euo pipefail
mkdir -p reports

echo "== flake8 (style, max line 100, max McCabe complexity 10)"
flake8 app tests --tee --output-file=reports/flake8.txt

echo "== pylint (fail under 9.5/10)"
pylint app --output-format=parseable --fail-under=9.5 | tee reports/pylint.txt

echo "== radon (cyclomatic complexity and maintainability index)"
radon cc app -s -a | tee reports/radon-cc.txt
radon mi app -s | tee reports/radon-mi.txt

echo "== xenon gate (no function worse than B, modules and average A)"
xenon --max-absolute B --max-modules A --max-average A app
echo "Local quality gates passed"
