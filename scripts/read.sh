#!/usr/bin/env bash
# Call the Logseq HTTP API, but only for methods on the read-only allow-list below.
# Delegates to call.sh, which handles auth/URL/JSON — this script's only job is to
# reject anything that isn't a known non-mutating method, so it's safe to
# auto-approve in permission config without approving call.sh itself.
#
# Usage:
#   read.sh [--raw] [--depth N] [--ref-depth N] <method> [json-args-array]
#
# By default, block-tree methods (getPageBlocksTree, getBlock, ...) and datalog
# query methods (datascriptQuery, q, customQuery) are rendered as a text outline
# instead of raw JSON — see render_outline.py for the format. Pass --raw to get
# the old pretty-JSON behavior for any method. --depth N (default 1) controls how
# many levels of nested block embeds get fully expanded inline. --ref-depth N
# (default 5) bounds how many chained "reference to a reference" hops get
# resolved before falling back to raw text — guards against reference cycles;
# plain references otherwise always resolve to their final text regardless of
# --depth (which only limits embeds).
#
# Examples:
#   read.sh logseq.Editor.getPageBlocksTree '["My Page"]'
#   read.sh --raw logseq.Editor.getPageBlocksTree '["My Page"]'
#   read.sh --depth 2 logseq.Editor.getPageBlocksTree '["My Page"]'
#   read.sh logseq.DB.datascriptQuery '["[:find (pull ?b [*]) :where [?b :block/marker \"TODO\"]]"]'
#
# The allow-list is curated by hand from the Logseq Plugin API's IAppProxy/IEditorProxy/
# IDBProxy interfaces (libs/src/LSPlugin.ts upstream) — it is deliberately NOT a
# namespace-level wildcard (e.g. "logseq.App.*") because some methods in those same
# namespaces are mutating or dangerous (logseq.App.quit, logseq.App.relaunch,
# logseq.App.execGitCommand, logseq.App.setStateFromStore, logseq.Editor.appendBlockInPage,
# logseq.Editor.removeBlock, etc). When Logseq adds a new read method you want to use,
# add it here explicitly rather than loosening the match pattern.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

array_contains() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [[ "$needle" == "$x" ]] && return 0
  done
  return 1
}

raw=false
depth=1
ref_depth=5
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --raw)
      raw=true
      shift
      ;;
    --depth)
      if [[ $# -lt 2 ]]; then
        echo "error: --depth requires a value" >&2
        exit 1
      fi
      depth="$2"
      shift 2
      ;;
    --ref-depth)
      if [[ $# -lt 2 ]]; then
        echo "error: --ref-depth requires a value" >&2
        exit 1
      fi
      ref_depth="$2"
      shift 2
      ;;
    *)
      echo "error: unknown flag '$1'" >&2
      exit 1
      ;;
  esac
done

# Curated from the Logseq Plugin API's IAppProxy/IEditorProxy/IDBProxy interfaces, then
# pruned to what this HTTP bridge actually implements (Logseq's exposed method set is a
# subset of the full plugin API and varies by version/graph type — several plausible
# candidates like getAllTags, getTodayPage, getFileContent, checkCurrentIsDbGraph
# returned "MethodNotExist" when probed live and were dropped).
READ_ONLY_METHODS=(
  # logseq.App.* -- info/state getters only, no registration/mutation/lifecycle methods
  logseq.App.getUserConfigs
  logseq.App.getStateFromStore
  logseq.App.getCurrentGraph
  logseq.App.getCurrentGraphConfigs
  logseq.App.getCurrentGraphFavorites
  logseq.App.getCurrentGraphRecent
  logseq.App.getCurrentGraphTemplates
  logseq.App.getTemplate
  logseq.App.existTemplate
  logseq.App.getExternalPlugin
  # logseq.Editor.* -- get*/check* only, no insert/append/update/remove/move/set/edit/delete
  logseq.Editor.checkEditing
  logseq.Editor.getEditingCursorPosition
  logseq.Editor.getEditingBlockContent
  logseq.Editor.getCurrentPage
  logseq.Editor.getCurrentBlock
  logseq.Editor.getSelectedBlocks
  logseq.Editor.getCurrentPageBlocksTree
  logseq.Editor.getPageBlocksTree
  logseq.Editor.getPageLinkedReferences
  logseq.Editor.getPagesFromNamespace
  logseq.Editor.getPagesTreeFromNamespace
  logseq.Editor.getBlock
  logseq.Editor.getPage
  logseq.Editor.getAllPages
  logseq.Editor.getPreviousSiblingBlock
  logseq.Editor.getNextSiblingBlock
  logseq.Editor.getBlockProperty
  logseq.Editor.getBlockProperties
  # logseq.DB.* -- query only, excludes setFileContent
  logseq.DB.q
  logseq.DB.customQuery
  logseq.DB.datascriptQuery
)

if [[ $# -lt 1 ]]; then
  echo "usage: $0 [--raw] [--depth N] [--ref-depth N] <method> [json-args-array]" >&2
  exit 1
fi

if ! [[ "$depth" =~ ^[0-9]+$ ]]; then
  echo "error: --depth must be a non-negative integer, got: $depth" >&2
  exit 1
fi

if ! [[ "$ref_depth" =~ ^[0-9]+$ ]]; then
  echo "error: --ref-depth must be a non-negative integer, got: $ref_depth" >&2
  exit 1
fi

method="$1"

allowed=false
if array_contains "$method" "${READ_ONLY_METHODS[@]}"; then
  allowed=true
fi

if [[ "$allowed" != true ]]; then
  echo "error: '${method}' is not on read.sh's read-only allow-list." >&2
  echo "if it's genuinely non-mutating, add it to READ_ONLY_METHODS in $0." >&2
  echo "otherwise use call.sh directly (it will prompt for approval, by design)." >&2
  exit 1
fi

if [[ "$raw" == true ]]; then
  exec "${SCRIPT_DIR}/call.sh" "$@"
fi

# Methods whose result is a block/page tree, rendered via --mode tree.
# getPageLinkedReferences is deliberately NOT here: it returns
# Array<[PageEntity, BlockEntity[]]> (page+blocks pairs), a different shape
# render_tree's resolve_child doesn't unwrap -- adding it would silently
# mis-render as "(no results)" instead of falling through to raw JSON.
TREE_METHODS=(
  logseq.Editor.getCurrentPageBlocksTree
  logseq.Editor.getPageBlocksTree
  logseq.Editor.getBlock
  logseq.Editor.getPagesTreeFromNamespace
  logseq.Editor.getSelectedBlocks
  logseq.Editor.getCurrentBlock
)

# Methods whose result is datalog query rows, rendered via --mode query.
QUERY_METHODS=(
  logseq.DB.q
  logseq.DB.customQuery
  logseq.DB.datascriptQuery
)

mode=""
if array_contains "$method" "${TREE_METHODS[@]}"; then
  mode="tree"
elif array_contains "$method" "${QUERY_METHODS[@]}"; then
  mode="query"
fi

if [[ -z "$mode" ]]; then
  # Flat metadata methods (getCurrentGraph, getUserConfigs, ...) — nothing to
  # outline, just pretty-print like today.
  exec "${SCRIPT_DIR}/call.sh" "$@"
fi

if ! response="$("${SCRIPT_DIR}/call.sh" "$@")"; then
  # call.sh already printed its own error to stderr.
  exit 1
fi

printf '%s' "$response" | python3 "${SCRIPT_DIR}/render_outline.py" --mode "$mode" --depth "$depth" --ref-depth "$ref_depth"
