# Bug Issues: worktree-feature+read-sh-outline vs dev

## B1. HIGH -- Embed-beyond-depth-budget fallback text is reprocessed as a fresh reference, corrupting output

**File:** [scripts/render_outline.py](../../scripts/render_outline.py), lines 106-129

```python
def render_content(content, depth_budget, ref_depth, out_lines, indent):
    def replace_embed(m):
        uuid = m.group(1)
        if depth_budget > 0:
            block = resolve_block(uuid, include_children=True)
            if block is None:
                return f"[unresolved embed]((embed {uuid}))"
            render_block(block, indent + 1, depth_budget - 1, ref_depth, out_lines, bullet="▸")
            return "(embed, expanded below)"
        block = resolve_block(uuid, include_children=False)
        text = first_line(block.get("content") if block else None)
        return f"[{text}]((embed {uuid}))"

    without_embeds = EMBED_RE.sub(replace_embed, content)

    def replace_ref(m):
        uuid = m.group(1)
        text = resolve_ref_text(uuid, ref_depth, set())
        return f"[{text}](({uuid}))"

    return REF_RE.sub(replace_ref, without_embeds)
```

When an embed is beyond the `--depth` budget, the fallback path (line 118-120) sets `text` to the raw, unresolved `first_line()` of the embed target's own content — it does **not** go through `resolve_ref_text`, unlike every other reference-resolution path in this file. If the embed target's content happens to itself be a bare pointer reference (a block whose entire first line is `((some-uuid))`, which is exactly the "reference to a reference" pattern this same branch elsewhere goes out of its way to resolve), that raw `((some-uuid))` text ends up embedded verbatim into the string returned by `replace_embed`.

The critical problem is what happens next: `EMBED_RE.sub(replace_embed, content)` runs *first*, producing `without_embeds`. `REF_RE.sub(replace_ref, without_embeds)` then runs over the **already-substituted** string — including the literal `((some-uuid))` text that `replace_embed` just inserted as part of its "unresolved" fallback display text. `REF_RE` matches that substring as if it were original content, and `replace_ref` resolves it (correctly, in isolation), but the result is nonsensical nested-bracket output.

Reproduced with a fixture: an embed whose target's content is itself a pointer to a real-text block, rendered at `--depth 0`:

```json
[{"content": "See: {{embed ((aaaa9999-0000-0000-0000-000000000000))}}", "children": []}]
```

where block `aaaa9999` has content `((aaaa8888-0000-0000-0000-000000000000))\nid:: aaaa9999-...` and block `aaaa8888` has content `real final text`. Running `render_outline.py --mode tree --depth 0` on this produces:

```
- See: [[real final text]((aaaa8888-0000-0000-0000-000000000000))]((embed aaaa9999-0000-0000-0000-000000000000))
```

instead of the intended, single-bracket form matching how a plain reference to the same pointer chain would render:

```
- See: [real final text]((embed aaaa9999-0000-0000-0000-000000000000))
```

This is not a rare shape — the branch's own commit history shows the author testing exactly this "reference to a reference" pattern in the user's real Logseq graph (see commit `b2d8a6b`), and embed-of-a-pointer-block is a natural extension of that same pattern once any embed nesting exceeds `--depth` (which defaults to only `1`, so embeds nested inside an already-expanded embed hit this path routinely in real graphs with multi-level embed usage).

**Impact:** Any embed that exceeds the depth budget and whose target is itself a pointer/reference block renders as corrupted, doubly-bracketed text (`[[text]((uuid))]((embed uuid))`) instead of the clean, single-bracket resolved form the rest of the renderer produces. This defeats the purpose of the feature for the calling agent (the whole point is to avoid manually parsing markup) and could confuse downstream reasoning about which uuid a bracket actually refers to.

**Suggested fix:** Route the beyond-depth-budget fallback through `resolve_ref_text` (the same function `replace_ref` already uses), so it benefits from the same chain-resolution and cycle-guard logic instead of returning a raw, re-matchable `((uuid))` substring:

```python
        block = resolve_block(uuid, include_children=False)
        if block is None:
            return f"[unresolved embed]((embed {uuid}))"
        line = first_line(block.get("content"))
        m = FULL_REF_RE.match(line)
        if m:
            text = resolve_ref_text(m.group(1), ref_depth, {uuid})
        else:
            text = line
        return f"[{text}]((embed {uuid}))"
```

More generally, doing the embed substitution and the reference substitution in two sequential `re.sub` passes over the same string is fragile whenever either replacement can itself produce text matching the other pattern — worth a comment or a structural change (e.g. building the output by scanning once, dispatching per-match to either an embed or a ref handler) to make this class of bug harder to reintroduce.

## B2. MEDIUM -- Pointer-chain resolution only inspects the first line, silently discarding any other real content in the pointer block

**File:** [scripts/render_outline.py](../../scripts/render_outline.py), lines 87-103

```python
def resolve_ref_text(uuid, ref_budget, seen):
    if uuid in seen:
        return f"(({uuid}))"
    block = resolve_block(uuid, include_children=False)
    if block is None:
        return "(unresolved reference)"
    line = first_line(block.get("content"))
    m = FULL_REF_RE.match(line)
    if m and ref_budget > 0:
        return resolve_ref_text(m.group(1), ref_budget - 1, seen | {uuid})
    return line
```

`first_line()` is used here specifically to skip the `id:: <uuid>` property line Logseq appends to any block that gets referenced — a real, well-understood constraint (see the module's own comment on `FULL_REF_RE`). But the same `first_line()` call also silently discards **any other text** the pointer block might have on subsequent lines, not just Logseq-generated property lines. If a block's content is `((other-uuid))\nplus an extra annotation line I wrote here` (a bare reference plus the author's own free-text note, written with a soft line break rather than as a separate child block — a normal way to annotate a reference in Logseq), `FULL_REF_RE.match(line)` still matches on the first line alone, the chain gets resolved, and the annotation is never shown anywhere in the output.

Reproduced with a fixture:

```json
[{"content": "Note: ((aaaa7777-0000-0000-0000-000000000000))", "children": []}]
```

where block `aaaa7777` has content `((aaaa6666-...))\nplus an extra annotation line I wrote here` and block `aaaa6666` has content `the actual TODO text`. Running `render_outline.py --mode tree --depth 1` produces:

```
- Note: [the actual TODO text]((aaaa7777-0000-0000-0000-000000000000))
```

The annotation text ("plus an extra annotation line I wrote here") is nowhere in the output, with no indication anything was dropped.

**Impact:** Real user-authored content silently disappears from the outline whenever a reference is annotated with free text on a line after it (rather than via a `key:: value` property, which is the only "extra line" case this code path was actually designed to tolerate). Since this is silent — no error, no truncation marker — the calling agent has no way to know it's working from an incomplete view of the page.

**Suggested fix:** Only treat the block as a chainable pointer if every line after the first is a recognized property line (`key:: value` syntax), rather than assuming any trailing content is safe to drop:

```python
PROPERTY_LINE_RE = re.compile(r"^[A-Za-z0-9_-]+::\s")

def resolve_ref_text(uuid, ref_budget, seen):
    if uuid in seen:
        return f"(({uuid}))"
    block = resolve_block(uuid, include_children=False)
    if block is None:
        return "(unresolved reference)"
    content = (block.get("content") or "").strip()
    lines = content.splitlines()
    is_pure_pointer = bool(lines) and FULL_REF_RE.match(lines[0]) and all(
        PROPERTY_LINE_RE.match(l) for l in lines[1:]
    )
    if is_pure_pointer and ref_budget > 0:
        return resolve_ref_text(FULL_REF_RE.match(lines[0]).group(1), ref_budget - 1, seen | {uuid})
    return first_line(content)
```

## B3. MEDIUM -- No subprocess timeout: a stalled Logseq API call hangs the entire render indefinitely

**File:** [scripts/render_outline.py](../../scripts/render_outline.py), lines 38-52

```python
def call_logseq(method, args):
    try:
        proc = subprocess.run(
            [CALL_SH, method, json.dumps(args)],
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
```

`subprocess.run` here has no `timeout=` argument. `call.sh` itself sets `--connect-timeout 3` on its `curl` call (bounding only the TCP connect phase), but places no bound on how long the request/response can take once connected — if the Logseq HTTP server accepts the connection but never responds (e.g. it's busy, wedged, or a very large page query is slow), `curl` — and therefore this `subprocess.run` call, and therefore the whole `render_outline.py` process, and therefore `read.sh` — blocks forever with no feedback.

This is a real risk specifically *because* of the feature this branch adds: `render_outline.py` now makes an unbounded number of extra `getBlock` calls per rendered page (one per reference, one per embed, recursively for chains and nested embeds), each one a fresh opportunity to hang. A page with many references that used to be a single `call.sh` invocation is now N+1 invocations, each individually unprotected by any timeout.

**Impact:** A single slow or wedged `getBlock` call — for any one of potentially dozens of references/embeds on a page — hangs the entire `read.sh` invocation with no error message and no way for the calling agent to distinguish "still working" from "stuck forever" other than an external timeout/interrupt.

**Suggested fix:** Add a reasonable timeout and treat expiry the same as any other resolution failure:

```python
def call_logseq(method, args):
    try:
        proc = subprocess.run(
            [CALL_SH, method, json.dumps(args)],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    ...
```
