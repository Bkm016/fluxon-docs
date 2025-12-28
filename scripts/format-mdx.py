#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from dataclasses import dataclass
from pathlib import Path
import re
import sys
from typing import Iterable, Iterator, List, Optional, Sequence, Tuple


PUNCT_BREAK = set(
    " \t"
    "，。,.;；：:、"
    "!！?？"
    ")）]】}》〉"
    "/"
)


def approx_display_width(text: str) -> int:
    width = 0
    for ch in text:
        width += 1 if ord(ch) <= 127 else 2
    return width


@dataclass(frozen=True)
class Token:
    raw: str
    visible: str
    width: int
    breakable_after: bool
    is_whitespace: bool


CODE_SPAN_RE = re.compile(r"^(`+)(.*)\1$", re.DOTALL)
LINK_RE = re.compile(r"^\[([^\]]+)\]\([^)]+\)$")
TAG_RE = re.compile(r"^<[^>]*>$")


def tokenize_inline(text: str) -> List[Token]:
    tokens: List[Token] = []
    i = 0
    while i < len(text):
        ch = text[i]

        if ch == "`":
            run = 1
            while i + run < len(text) and text[i + run] == "`":
                run += 1
            delim = "`" * run
            j = text.find(delim, i + run)
            if j != -1:
                raw = text[i : j + run]
                m = CODE_SPAN_RE.match(raw)
                visible = m.group(2) if m else raw
                width = approx_display_width(visible)
                tokens.append(
                    Token(
                        raw=raw,
                        visible=visible,
                        width=width,
                        breakable_after=True,
                        is_whitespace=False,
                    )
                )
                i = j + run
                continue

        if ch == "[":
            close = text.find("]", i + 1)
            if close != -1 and close + 1 < len(text) and text[close + 1] == "(":
                close_paren = text.find(")", close + 2)
                if close_paren != -1:
                    raw = text[i : close_paren + 1]
                    m = LINK_RE.match(raw)
                    visible = m.group(1) if m else raw
                    width = approx_display_width(visible)
                    tokens.append(
                        Token(
                            raw=raw,
                            visible=visible,
                            width=width,
                            breakable_after=True,
                            is_whitespace=False,
                        )
                    )
                    i = close_paren + 1
                    continue

        if ch == "<":
            close = text.find(">", i + 1)
            if close != -1:
                raw = text[i : close + 1]
                visible = ""
                width = 0
                tokens.append(
                    Token(
                        raw=raw,
                        visible=visible,
                        width=width,
                        breakable_after=False,
                        is_whitespace=False,
                    )
                )
                i = close + 1
                continue

        raw = ch
        visible = ch
        width = approx_display_width(visible)
        is_ws = ch.isspace()
        breakable = is_ws or (ch in PUNCT_BREAK)
        tokens.append(
            Token(
                raw=raw,
                visible=visible,
                width=width,
                breakable_after=breakable,
                is_whitespace=is_ws,
            )
        )
        i += 1

    return tokens


def wrap_inline(text: str, max_width: int) -> List[str]:
    tokens = tokenize_inline(text)
    lines: List[str] = []

    current: List[Token] = []
    current_width = 0
    last_break: Optional[int] = None

    def flush_line(toks: Sequence[Token]) -> None:
        raw = "".join(t.raw for t in toks).rstrip()
        if raw != "" or lines:
            lines.append(raw)

    def strip_leading_ws(toks: List[Token]) -> List[Token]:
        k = 0
        while k < len(toks) and toks[k].is_whitespace:
            k += 1
        return toks[k:]

    def recompute_breakpoint() -> None:
        nonlocal last_break
        last_break = None
        for idx, t in enumerate(current):
            if t.breakable_after:
                last_break = idx + 1

    for token in tokens:
        while True:
            if not current and token.is_whitespace:
                break

            if not current:
                current.append(token)
                current_width = token.width
                last_break = 1 if token.breakable_after else None
                break

            if current_width + token.width <= max_width:
                current.append(token)
                current_width += token.width
                if token.breakable_after:
                    last_break = len(current)
                break

            if last_break is not None and last_break > 0:
                flush_line(current[:last_break])
                remainder = strip_leading_ws(list(current[last_break:]))
                current = remainder
                current_width = sum(t.width for t in current)
                recompute_breakpoint()
                continue

            flush_line(current)
            current = []
            current_width = 0
            last_break = None
            continue

    if current:
        flush_line(current)

    if not lines:
        return [""]
    return lines


LIST_PREFIX_RE = re.compile(r"^(\s*[-*+]\s+)(.*)$")
ORDERED_PREFIX_RE = re.compile(r"^(\s*\d+[.)]\s+)(.*)$")
BLOCKQUOTE_PREFIX_RE = re.compile(r"^(\s*>+\s+)(.*)$")
HEADING_RE = re.compile(r"^\s*#{1,6}\s+")


def split_prefix(line: str) -> Tuple[str, str, str]:
    m = BLOCKQUOTE_PREFIX_RE.match(line)
    if m:
        return m.group(1), m.group(2), "blockquote"
    m = LIST_PREFIX_RE.match(line)
    if m:
        return m.group(1), m.group(2), "list"
    m = ORDERED_PREFIX_RE.match(line)
    if m:
        return m.group(1), m.group(2), "ordered"
    leading = re.match(r"^\s*", line).group(0)
    return leading, line[len(leading) :], "plain"


def wrap_line(line: str, max_width: int) -> List[str]:
    if line.strip() == "":
        return [""]
    if HEADING_RE.match(line):
        return [line.rstrip()]
    if line.lstrip().startswith("|"):
        return [line.rstrip()]

    prefix, content, kind = split_prefix(line.rstrip())
    content_lines = wrap_inline(content, max_width)
    if len(content_lines) == 1:
        return [prefix + content_lines[0]]

    if kind == "blockquote":
        cont_prefix = prefix
    elif kind in ("list", "ordered"):
        cont_prefix = " " * len(prefix)
    else:
        cont_prefix = prefix

    out = [prefix + content_lines[0]]
    out.extend(cont_prefix + ln for ln in content_lines[1:])
    return out


def iter_mdx_files(root: Path) -> Iterator[Path]:
    for path in root.rglob("*.mdx"):
        if ".mintlify" in path.parts:
            continue
        if "node_modules" in path.parts:
            continue
        yield path


def format_mdx_file(path: Path, max_width: int) -> str:
    original = path.read_text(encoding="utf-8")
    lines = original.splitlines()

    out_lines: List[str] = []
    in_frontmatter = False
    frontmatter_done = False
    in_code_fence = False

    for i, line in enumerate(lines):
        if not frontmatter_done:
            out_lines.append(line.rstrip())
            stripped = line.lstrip("\ufeff").strip()
            if stripped == "---":
                in_frontmatter = not in_frontmatter
                if not in_frontmatter:
                    frontmatter_done = True
            continue

        if line.strip().startswith("```"):
            out_lines.append(line.rstrip())
            in_code_fence = not in_code_fence
            continue
        if in_code_fence:
            out_lines.append(line.rstrip())
            continue

        wrapped = wrap_line(line, max_width)
        out_lines.extend(wrapped)

    if original.endswith("\n"):
        return "\n".join(out_lines) + "\n"
    return "\n".join(out_lines)


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description="Format Mintlify MDX files by soft-wrapping long lines.")
    parser.add_argument(
        "--root",
        default="mintlify-docs",
        help="Docs root directory (default: mintlify-docs)",
    )
    parser.add_argument(
        "--max-visible-width",
        type=int,
        default=int(os.environ.get("FLUXON_DOCS_MAX_VISIBLE_LINE_WIDTH", "120")),
        help="Max visible line width (ASCII=1, non-ASCII=2). Default 120; overridable via FLUXON_DOCS_MAX_VISIBLE_LINE_WIDTH.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check only; exit non-zero if formatting would change files.",
    )
    args = parser.parse_args(list(argv))

    root = Path(args.root).resolve()
    if not root.exists():
        print(f"error: root does not exist: {root}", file=sys.stderr)
        return 2
    if args.max_visible_width < 0:
        print("error: --max-visible-width must be >= 0", file=sys.stderr)
        return 2

    changed: List[Path] = []
    for path in iter_mdx_files(root):
        formatted = format_mdx_file(path, args.max_visible_width)
        original = path.read_text(encoding="utf-8")
        if formatted != original:
            changed.append(path)
            if not args.check:
                path.write_text(formatted, encoding="utf-8", newline="\n")

    if args.check:
        if changed:
            for p in changed:
                print(f"needs format: {p.as_posix()}")
            return 1
        return 0

    if changed:
        print(f"formatted {len(changed)} file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

