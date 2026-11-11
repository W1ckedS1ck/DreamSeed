#!/bin/bash
# Unit tests for the Python tooling — ONE entry point for local `make test` and CI.
#
# Coverage is scoped to the modules the pytest suite actually exercises:
#   * scripts/env_loader.py and scripts/lint_actions.py are driven by the .env contract/fuzz and by
#     the lint run itself (not by pytest), so counting them here would only dilute the number;
#   * scripts/telegram_bot.py is network-bound; its pure helpers are covered by test_bot_helpers.
# The floor is measured (82-83 %) minus ~2 points, so only a real regression fails it.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${PYTHON:-python3}"
exec "$PY" -m pytest tests/unit -q \
    --cov=scripts \
    --cov=lib \
    --cov-fail-under=80
