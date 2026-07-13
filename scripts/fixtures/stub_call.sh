#!/usr/bin/env bash
# Fake call.sh for fixture tests: answers logseq.Editor.getBlock from
# blocks_db.json sitting alongside this script (looked up relative to this
# script, not the cwd, so run_tests.sh can copy it anywhere). render_outline.py
# never calls any other method, so nothing else needs to be stubbed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

method="$1"
args="$2"

if [[ "$method" != "logseq.Editor.getBlock" ]]; then
  echo "stub_call.sh: unexpected method '$method'" >&2
  exit 1
fi

uuid="$(python3 -c "import json, sys; print(json.loads(sys.argv[1])[0])" "$args")"
python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    db = json.load(f)
print(json.dumps(db.get(sys.argv[2])))
" "$SCRIPT_DIR/blocks_db.json" "$uuid"
