#!/usr/bin/env bash
# Call the local Logseq HTTP Plugin API.
#
# Usage:
#   call.sh <method> [json-args-array]
#
# Examples:
#   call.sh logseq.App.getCurrentGraph
#   call.sh logseq.Editor.getPageBlocksTree '["My Page"]'
#   call.sh logseq.Editor.appendBlockInPage '["Jul 9th, 2026", "# Report title"]'
#
# Config via env vars: LOGSEQ_TOKEN (required), LOGSEQ_HOST (default 127.0.0.1),
# LOGSEQ_PORT (default 12315).

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "error: this script requires jq (used to build/pretty-print JSON)." >&2
  exit 1
fi

token="${LOGSEQ_TOKEN-}"
if [[ -z "$token" ]]; then
  echo "error: LOGSEQ_TOKEN is not set. Generate a token in Logseq (toolbar API icon > Start server) and export it." >&2
  exit 1
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <method> [json-args-array]" >&2
  exit 1
fi

method="$1"
args="${2:-[]}"

host="${LOGSEQ_HOST:-127.0.0.1}"
port="${LOGSEQ_PORT:-12315}"
url="http://${host}:${port}/api"

if ! body="$(jq -n --arg m "$method" --argjson a "$args" '{method: $m, args: $a}' 2>&1)"; then
  echo "error: second argument must be a valid JSON array, got: $args" >&2
  exit 1
fi

http_code_and_body="$(curl -sS -w '\n%{http_code}' \
  --connect-timeout 3 \
  -X POST "$url" \
  -H "Authorization: Bearer ${LOGSEQ_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$body" 2>&1)" || {
  echo "error: could not reach Logseq HTTP API at ${url}." >&2
  echo "check that Logseq is running, HTTP APIs server is enabled (Settings > Features), and the server was started (toolbar API icon > Start server)." >&2
  exit 1
}

http_code="$(printf '%s' "$http_code_and_body" | tail -n1)"
response_body="$(printf '%s' "$http_code_and_body" | sed '$d')"

if [[ "$http_code" != "200" ]]; then
  echo "error: Logseq API returned HTTP ${http_code}:" >&2
  echo "$response_body" >&2
  exit 1
fi

printf '%s' "$response_body" | jq .
