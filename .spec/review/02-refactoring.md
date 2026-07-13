# Refactoring Suggestions: worktree-feature+read-sh-outline vs dev

## R1. MEDIUM -- No committed regression tests despite the original plan specifying a fixture-based test suite

**File:** [scripts/render_outline.py](../../scripts/render_outline.py) (whole file, new in this branch)

The planning document for this feature (written before implementation started) laid out a concrete verification approach: hand-written fixture JSON files (`fixtures/tree_simple.json`, `fixtures/tree_ref.json`, `fixtures/tree_embed_within_depth.json`, `fixtures/query_with_content.json`, `fixtures/query_fields_only.json`) fed directly into `render_outline.py` via stdin, plus a stubbed `call.sh` for the cases that need a resolution call, specifically to verify indentation, blank-block skipping, marker display, reference resolution, embed expansion at and beyond the depth budget, and datalog row rendering.

None of this was committed. A repo-wide search for test or fixture files (`find . -iname "*test*" -o -iname "*fixture*"`) returns nothing. The behavior this plan called out as needing explicit verification — reference-chain resolution, embed depth-budget fallback, cycle detection — is exactly the class of logic that later turned out to have real bugs (see [Bug Issues](./01-bugs.md) B1 and B2), which were only caught during this review by hand-building throwaway fixtures and a stubbed `call.sh` in a temp directory, then discarding them. That verification effort is not reusable — the next change to this file has no regression net and could reintroduce the same bugs, or new ones, silently.

**Impact:** Any future change to `render_outline.py` (e.g. the fixes suggested in B1/B2/B3, or a new feature) has nothing to run to confirm the existing reference/embed/query rendering behavior didn't regress. Bugs in this area are easy to introduce (as B1 demonstrates — the interaction between two sequential `re.sub` passes is subtle) and easy to miss without dedicated fixtures, since there's no live Logseq server in most development/CI environments to smoke-test against.

**Suggested fix:** Commit a small `fixtures/` directory alongside the script with the JSON shapes described in the plan, a stub `call.sh` (a short script that pattern-matches on the `getBlock` uuid argument and echoes canned JSON) for the cases needing resolution, and a lightweight test runner (even a plain shell script that runs `render_outline.py` against each fixture and diffs against an expected-output file would suffice — no new test framework dependency is required). At minimum, add fixtures covering: a plain reference, a chained "reference to a reference," a cyclic reference, an embed within the depth budget, and an embed beyond the depth budget whose target is itself a pointer block (this last one is exactly the shape that reproduces B1).

## R2. LOW -- `TREE_METHODS` omits other block-shaped read methods, which silently fall through to raw JSON

**File:** [scripts/read.sh](../../scripts/read.sh), lines 149-154

```bash
TREE_METHODS=(
  logseq.Editor.getCurrentPageBlocksTree
  logseq.Editor.getPageBlocksTree
  logseq.Editor.getBlock
  logseq.Editor.getPagesTreeFromNamespace
)
```

`READ_ONLY_METHODS` (lines 75-110) also allow-lists `logseq.Editor.getSelectedBlocks`, `logseq.Editor.getPageLinkedReferences`, and `logseq.Editor.getCurrentBlock` — all of which return the same block-shaped JSON (`content`/`children`/`marker`/`uuid`) that `render_outline.py --mode tree` is designed to render. Because these three aren't in `TREE_METHODS`, calling them without `--raw` falls through to the `mode=""` branch (lines 179-183) and prints raw pretty-JSON instead of an outline — with no indication to the calling agent that this is different from every other block-returning method, since there's no error, just silently different (worse) output shape.

**Impact:** An agent calling `getSelectedBlocks`, `getPageLinkedReferences`, or `getCurrentBlock` — all reasonable things to call from this skill — gets raw JSON it has to hand-parse, defeating the purpose of this branch's core feature for exactly the methods where a user is likely to want the same convenience (e.g. "what links to this page" via `getPageLinkedReferences` is a natural read to want summarized, not raw-dumped).

**Suggested fix:** Add the three methods to `TREE_METHODS`:

```bash
TREE_METHODS=(
  logseq.Editor.getCurrentPageBlocksTree
  logseq.Editor.getPageBlocksTree
  logseq.Editor.getBlock
  logseq.Editor.getPagesTreeFromNamespace
  logseq.Editor.getSelectedBlocks
  logseq.Editor.getPageLinkedReferences
  logseq.Editor.getCurrentBlock
)
```

Worth first confirming `getPageLinkedReferences`'s actual response shape live (it may return a list of `[page, blocks]` pairs rather than a flat block list) before assuming `render_tree`'s existing list-or-single-dict handling covers it as-is.

## R3. LOW -- Three near-identical bash "scan array for match" loops could be a single reusable function

**File:** [scripts/read.sh](../../scripts/read.sh), lines 129-135, 164-169, and 171-176

```bash
allowed=false
for m in "${READ_ONLY_METHODS[@]}"; do
  if [[ "$method" == "$m" ]]; then
    allowed=true
    break
  fi
done
```

```bash
mode=""
for m in "${TREE_METHODS[@]}"; do
  if [[ "$method" == "$m" ]]; then
    mode="tree"
    break
  fi
done
if [[ -z "$mode" ]]; then
  for m in "${QUERY_METHODS[@]}"; do
    if [[ "$method" == "$m" ]]; then
      mode="query"
      break
    fi
  done
fi
```

All three loops do the same thing: linear-scan a bash array for an exact string match against `$method`, breaking on the first hit. This is repeated with only the array name and the variable being set changed.

**Impact:** Purely a maintainability concern — no functional issue. Three copies of the same loop shape means any future fix to the matching logic (e.g. switching to a case-insensitive match, or building a combined lookup) has to be applied three times, and it's easy to update one copy and miss another.

**Suggested fix:** Factor into a small helper used by all three call sites:

```bash
array_contains() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [[ "$needle" == "$x" ]] && return 0
  done
  return 1
}

# ...
if array_contains "$method" "${READ_ONLY_METHODS[@]}"; then
  allowed=true
fi

# ...
if array_contains "$method" "${TREE_METHODS[@]}"; then
  mode="tree"
elif array_contains "$method" "${QUERY_METHODS[@]}"; then
  mode="query"
fi
```
