#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/test-state.sh"
bash "$SCRIPT_DIR/test-schema-keys.sh"
bash "$SCRIPT_DIR/test-pane.sh"

printf 'All agent-usage shell tests passed.\n'
