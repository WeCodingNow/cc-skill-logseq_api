# `logseq.DB.datascriptQuery` reference

For anything beyond "give me this one page's blocks" — cross-page search, filtering by property, tag, or task marker, joining a block to its page metadata — query the underlying Datascript DB directly instead of fetching whole pages and filtering client-side.

Call shape: `args = [datalogQueryString, ...extraInputs]`, e.g.

```
scripts/call.sh logseq.DB.datascriptQuery '["[:find (pull ?b [*]) :where [?b :block/marker \"TODO\"]]"]'
```

Results come back as an array of tuples, one per `:find` row — even with a single `(pull ...)` clause you get `[[{...}], [{...}]]`, not a flat list of maps. Unwrap the outer per-row array when processing results.

Use `(pull ?b [...])` in `:find` so you get full block/page maps back instead of bare entity ids. Nest pulls to avoid extra round-trips instead of querying again per result, e.g.:

```clojure
[:find (pull ?b [:block/content :block/uuid {:block/page [:block/journal-day :block/original-name]}])
 :where [?b :block/marker "TODO"]]
```

Note this is the raw Datascript schema, with `:block/x` keyword keys — different from the camelCase (`pathRefs`, `journal?`) shape that `getPageBlocksTree`/`getPage` return over the JS Editor API. Don't mix the two key styles up when reading results from each.

## Block/page schema

| Field | Notes |
|---|---|
| `:block/uuid` | Stable identifier, use this (not the entity id) when referencing a block from other API calls. |
| `:block/content` | Raw markdown, including `key:: value` property lines. |
| `:block/marker` | `TODO` / `DOING` / `DONE` / `NOW` / `LATER` / `CANCELED` / `CANCELLED` — **check for both cancellation spellings**, real graphs have both. |
| `:block/parent`, `:block/left` | Entity refs — expand via nested pull if you need the parent's own fields. |
| `:block/page` | Ref to the containing page; nest `{:block/page [:block/journal-day :block/original-name]}` to get journal/date context in one query. |
| `:block/properties` | Parsed map of block/page properties. |
| `:block/properties-text-values` | Same properties, as their original text form (e.g. keeps `[[Page]]` link syntax). |
| `:block/properties-order` | Property key order as authored. |
| `:block/refs` / `:block/path-refs` | Linked page/tag refs — what `[[...]]` and `#tag` resolve to. `path-refs` includes ancestor refs (e.g. refs from the page itself), `refs` is just this block's own. |
| `:block/journal-day` | Page-only. Int `YYYYMMDD`, zero-padded — good for date-range filtering/sorting, unlike the display name. |
| `:block/journal?` | Page-only. Bool. |
| `:block/name` | Page-only. Lowercased. |
| `:block/original-name` | Page-only. Display form, e.g. `"Jul 9th, 2026"`. Use this one when you need to show or link a page name to the user. |

## Example: open TODOs referencing a tag

```clojure
[:find (pull ?b [:block/uuid :block/content
                 {:block/page [:block/original-name]}])
 :where
 [?b :block/marker "TODO"]
 [?b :block/refs ?tag]
 [?tag :block/name "work"]]
```

## Example: journal entries in a date range

Filter on `:block/journal-day` (zero-padded int) rather than parsing `:block/original-name` strings — it sorts and range-filters correctly:

```clojure
[:find (pull ?p [:block/original-name :block/journal-day])
 :where
 [?p :block/journal? true]
 [?p :block/journal-day ?d]
 [(>= ?d 20260701)]
 [(<= ?d 20260709)]]
```
