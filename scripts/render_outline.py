#!/usr/bin/env python3
"""Render a Logseq API JSON response (read from stdin) as a text outline.

Used by read.sh as its default (non---raw) output path. Two input shapes:

  --mode tree   a block tree (or single block) from getPageBlocksTree /
                getCurrentPageBlocksTree / getBlock / getPagesTreeFromNamespace
  --mode query  datalog query rows from logseq.DB.{datascriptQuery,q,customQuery}

Inline `((uuid))` block references and `{{embed ((uuid))}}` block embeds found
in block content are resolved via extra logseq.Editor.getBlock calls (shelled
out to call.sh, so auth/URL handling isn't duplicated here), cached per-run.
"""

import argparse
import json
import os
import re
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CALL_SH = os.path.join(SCRIPT_DIR, "call.sh")

EMBED_RE = re.compile(r"\{\{embed\s+\(\(([0-9a-fA-F-]+)\)\)\s*\}\}")
REF_RE = re.compile(r"\(\(([0-9a-fA-F-]+)\)\)")
# A block whose *entire* content is a single reference — i.e. a pointer block
# rather than prose that happens to contain a reference. Chains of these
# (reference to a reference to a reference...) get chased to their final text
# instead of showing an unhelpful "[((uuid))]((uuid))".
FULL_REF_RE = re.compile(r"^\(\(([0-9a-fA-F-]+)\)\)$")

# uuid -> block dict (content only) / uuid -> block dict (with children)
_content_cache = {}
_tree_cache = {}


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


def resolve_block(uuid, include_children):
    cache = _tree_cache if include_children else _content_cache
    if uuid in cache:
        return cache[uuid]
    args = [uuid, {"includeChildren": True}] if include_children else [uuid]
    block = call_logseq("logseq.Editor.getBlock", args)
    cache[uuid] = block
    return block


def resolve_child(entry):
    """Return a hydrated block dict for a `children` array entry.

    Logseq only nests full block objects in `children` when the parent call
    asked for them (e.g. getPageBlocksTree, or getBlock with
    includeChildren). Otherwise each entry is an unresolved lookup-ref shaped
    like `["uuid", "<uuid>"]` — fetch it (with its own children) so the
    outline doesn't silently drop real content.
    """
    if isinstance(entry, dict):
        return entry
    if isinstance(entry, list) and len(entry) == 2 and entry[0] == "uuid":
        return resolve_block(entry[1], include_children=True)
    return None


def first_line(text):
    if not text:
        return "(empty block)"
    return " ".join(text.strip().splitlines()[:1]) or "(empty block)"


def resolve_ref_text(uuid, ref_budget, seen):
    """Resolve a plain `((uuid))` reference to display text, chasing chains of
    pointer blocks (blocks whose *first line* is itself a single reference,
    e.g. a plain `((uuid))` with only an `id:: ...` property line trailing
    it) to their final text. `ref_budget` bounds chain length and `seen`
    guards against cycles — both fall back to showing whatever text is at
    that point rather than resolving further."""
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


def render_content(content, depth_budget, ref_depth, out_lines, indent):
    """Return the rendered single-line content, having appended any expanded
    embed sub-outlines (as indented lines) to out_lines."""

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


def render_block(block, indent, depth_budget, ref_depth, out_lines, bullet="-"):
    content = (block.get("content") or "").strip()
    if content == "":
        for child in block.get("children") or []:
            resolved_child = resolve_child(child)
            if resolved_child is not None:
                render_block(resolved_child, indent, depth_budget, ref_depth, out_lines, bullet=bullet)
        return

    embed_lines = []
    rendered = render_content(content, depth_budget, ref_depth, embed_lines, indent)
    marker = block.get("marker")
    if marker and not rendered.upper().startswith(marker.upper()):
        rendered = f"{marker} {rendered}"

    out_lines.append("  " * indent + f"{bullet} {rendered}")
    out_lines.extend(embed_lines)

    for child in block.get("children") or []:
        resolved_child = resolve_child(child)
        if resolved_child is not None:
            render_block(resolved_child, indent + 1, depth_budget, ref_depth, out_lines)


def render_tree(data, depth_budget, ref_depth):
    out_lines = []
    if data is None:
        return "(no results)"
    blocks = data if isinstance(data, list) else [data]
    for block in blocks:
        resolved = resolve_child(block)
        if resolved is not None:
            render_block(resolved, 0, depth_budget, ref_depth, out_lines)
    return "\n".join(out_lines) if out_lines else "(no results)"


def format_metadata_value(value):
    if isinstance(value, dict):
        for key in (":block/original-name", ":block/name", ":block/content"):
            if key in value:
                return format_metadata_value(value[key])
        return json.dumps(value)
    if isinstance(value, list):
        return ", ".join(format_metadata_value(v) for v in value)
    return str(value)


def render_row_element(element, depth_budget, ref_depth, out_lines):
    if not isinstance(element, dict):
        return str(element)

    content = element.get(":block/content")
    if content is None:
        parts = []
        for key, value in element.items():
            if key in (":block/uuid",):
                continue
            label = key.replace(":block/", "")
            parts.append(f"{label}: {format_metadata_value(value)}")
        return ", ".join(parts) if parts else "(empty)"

    rendered = render_content(content.strip(), depth_budget, ref_depth, out_lines, 0)
    marker = element.get(":block/marker")
    if marker and not rendered.upper().startswith(marker.upper()):
        rendered = f"{marker} {rendered}"

    metadata_parts = []
    for key, value in element.items():
        if key in (":block/uuid", ":block/content", ":block/marker"):
            continue
        label = key.replace(":block/", "")
        metadata_parts.append(f"{label}: {format_metadata_value(value)}")

    if metadata_parts:
        rendered += " (" + ", ".join(metadata_parts) + ")"
    return rendered


def render_query(data, depth_budget, ref_depth):
    if not data:
        return "(no results)"
    out_lines = []
    for row in data:
        elements = row if isinstance(row, list) else [row]
        nested = []
        pieces = [render_row_element(el, depth_budget, ref_depth, nested) for el in elements]
        out_lines.append("- " + " | ".join(pieces))
        out_lines.extend("  " + line for line in nested)
    return "\n".join(out_lines) if out_lines else "(no results)"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["tree", "query"], required=True)
    parser.add_argument("--depth", type=int, default=1)
    parser.add_argument("--ref-depth", type=int, default=5)
    args = parser.parse_args()

    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else None
    except json.JSONDecodeError as e:
        print(f"error: could not parse Logseq API response as JSON: {e}", file=sys.stderr)
        sys.exit(1)

    if args.mode == "tree":
        print(render_tree(data, args.depth, args.ref_depth))
    else:
        print(render_query(data, args.depth, args.ref_depth))


if __name__ == "__main__":
    main()
