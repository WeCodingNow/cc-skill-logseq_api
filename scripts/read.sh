#!/usr/bin/env bash
# Call the Logseq HTTP API, but only for methods on the read-only allow-list below.
# Delegates to call.sh, which handles auth/URL/JSON — this script's only job is to
# reject anything that isn't a known non-mutating method, so it's safe to
# auto-approve in permission config without approving call.sh itself.
#
# Usage:
#   read.sh <method> [json-args-array]
#
# Examples:
#   read.sh logseq.Editor.getPageBlocksTree '["My Page"]'
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
  echo "usage: $0 <method> [json-args-array]" >&2
  exit 1
fi

method="$1"

allowed=false
for m in "${READ_ONLY_METHODS[@]}"; do
  if [[ "$method" == "$m" ]]; then
    allowed=true
    break
  fi
done

if [[ "$allowed" != true ]]; then
  echo "error: '${method}' is not on read.sh's read-only allow-list." >&2
  echo "if it's genuinely non-mutating, add it to READ_ONLY_METHODS in $0." >&2
  echo "otherwise use call.sh directly (it will prompt for approval, by design)." >&2
  exit 1
fi

exec "${SCRIPT_DIR}/call.sh" "$@"
