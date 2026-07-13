#!/usr/bin/env bash
# Regression test runner for render_outline.py: runs each fixture listed in
# manifest.txt through a copy of render_outline.py backed by a stubbed
# call.sh (stub_call.sh, answering getBlock from blocks_db.json) -- no live
# Logseq instance needed. Diffs stdout against <name>.expected.txt and exits
# non-zero if anything doesn't match.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp "$SCRIPT_DIR/../render_outline.py" "$TMP/render_outline.py"
cp "$SCRIPT_DIR/stub_call.sh" "$TMP/call.sh"
cp "$SCRIPT_DIR/blocks_db.json" "$TMP/blocks_db.json"
chmod +x "$TMP/call.sh"

pass=0
fail=0

while read -r name mode depth ref_depth; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  input="$SCRIPT_DIR/${name}.json"
  expected="$SCRIPT_DIR/${name}.expected.txt"
  actual_file="$TMP/${name}.actual.txt"
  python3 "$TMP/render_outline.py" --mode "$mode" --depth "$depth" --ref-depth "$ref_depth" \
    < "$input" > "$actual_file"
  if diff -u "$expected" "$actual_file" >/dev/null; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    diff -u "$expected" "$actual_file" || true
    fail=$((fail + 1))
  fi
done < "$SCRIPT_DIR/manifest.txt"

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
