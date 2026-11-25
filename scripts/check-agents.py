#!/usr/bin/env python3
"""Check that each symbol and path in backticks in an AGENTS.md exists in the tree.

The AGENTS.md files are the map of the code (see the root AGENTS.md). A rule
that names a symbol that a rename or a deletion removed is stale. This check
finds such a name.

For each inline code span in each AGENTS.md:

- A span with a `/` is a path. It must exist (from the repository root or from
  the folder of the AGENTS.md), or another tracked file must name it.
- A span that is a dotted chain of identifiers (`Pane.destroySurface`, `foo()`)
  must have all its identifiers as words in one tracked file that is not a map.
- A file name (`Hotkeys.swift`, `AppState+PinnedTabs`) must exist as a tracked
  file, or another tracked file must name it.

Every other span (a command with spaces, a config line, a chord, a value) is
not checked. The root AGENTS.md has at most 300 lines. A span in
scripts/check-agents-external.txt names code outside this tree and is not
checked; a line there that no AGENTS.md uses fails. Exit status 1 means that a
span was not found.
"""

import os
import re
import subprocess
import sys

ROOT = subprocess.run(
    ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
).stdout.strip()
# Names of code outside this tree (the ghostty fork, Apple, other tools).
EXTERNAL = "scripts/check-agents-external.txt"
SELF = "scripts/check-agents.py"
# Every session loads the root AGENTS.md, so it stays short.
ROOT_LINE_LIMIT = 300

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
CHAIN = re.compile(r"^[A-Za-z_]\w*(\.[A-Za-z_]\w*)*$")
FILE_EXTENSIONS = {
    "swift", "md", "yml", "yaml", "json", "sh", "py", "zig", "toml", "icns", "png",
    "plist", "xcconfig", "conf", "js", "mjs", "bats", "h", "tbd", "xcstrings", "icon",
    "entitlements", "txt", "patch", "c", "m", "car", "pkl",
}
SKIP_CHARACTERS = set(" <>*${}…=:@~,'\"|\\#%&;!?^[]")


def tracked_files():
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT, capture_output=True, check=True,
    ).stdout
    return [p for p in out.decode().split("\0") if p and os.path.isfile(os.path.join(ROOT, p))]


def load_corpus(files):
    """The words of each file, all text, and the file names, of every tracked
    file that is not a map (an AGENTS.md, its CLAUDE.md links, this check)."""
    words, text, names = [], [], set()
    for path in files:
        base = os.path.basename(path)
        names.add(base)
        names.add(os.path.splitext(base)[0])
        full = os.path.join(ROOT, path)
        if base in ("AGENTS.md", "CLAUDE.md") or os.path.islink(full) or path in (EXTERNAL, SELF):
            continue
        if os.path.getsize(full) > 4_000_000:
            continue
        try:
            with open(full, encoding="utf-8") as handle:
                content = handle.read()
        except (UnicodeDecodeError, OSError):
            continue
        words.append(set(IDENT.findall(content)))
        text.append(content)
    return words, "\n".join(text), names


def code_spans(markdown):
    """Yield (line number, span) for each inline code span outside fenced blocks."""
    fenced = False
    for number, line in enumerate(markdown.split("\n"), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        for match in re.finditer(r"(`+)(.+?)\1", line):
            yield number, match.group(2).strip()


def problem(span, folder, words, text, names):
    span = re.sub(r"\(.*\)$", "", span)
    if not span or any(c in SKIP_CHARACTERS for c in span) or "://" in span:
        return None
    if span.startswith("-") or span[0].isdigit():
        return None
    if "/" in span:
        path = span.removeprefix("./")
        if path.startswith("/") or ".." in path.split("/")[:1]:
            return None
        for base in (ROOT, folder):
            if os.path.exists(os.path.join(base, path)):
                return None
        if path.rstrip("/") in text:
            return None
        return "no such path"
    stem, _, extension = span.rpartition(".")
    if stem and extension in FILE_EXTENSIONS:
        if span in names or span in text:
            return None
        return "no such file"
    if re.match(r"^[A-Z]\w*\+\w+$", span):
        if span in names or span in text:
            return None
        return "no such file"
    if CHAIN.match(span):
        if span in names:
            return None
        parts = set(span.split("."))
        if not any(parts <= file_words for file_words in words):
            missing = [part for part in span.split(".") if not any(part in w for w in words)]
            if missing:
                return "no symbol " + ", ".join(missing)
            return "no file names all of " + ", ".join(sorted(parts))
    return None


def main():
    files = tracked_files()
    words, text, names = load_corpus(files)
    agents = sorted(p for p in files if os.path.basename(p) == "AGENTS.md" and not os.path.islink(os.path.join(ROOT, p)))
    with open(os.path.join(ROOT, EXTERNAL), encoding="utf-8") as handle:
        external = {line.strip() for line in handle if line.strip() and not line.startswith("#")}
    used = set()
    failures = 0
    for path in agents:
        folder = os.path.dirname(os.path.join(ROOT, path))
        with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
            markdown = handle.read()
        for number, span in code_spans(markdown):
            if span in external:
                used.add(span)
                continue
            reason = problem(span, folder, words, text, names)
            if reason:
                failures += 1
                print(f"{path}:{number}: `{span}`: {reason}")
    with open(os.path.join(ROOT, "AGENTS.md"), encoding="utf-8") as handle:
        root_lines = handle.read().count("\n")
    if root_lines > ROOT_LINE_LIMIT:
        failures += 1
        print(f"AGENTS.md: {root_lines} lines, more than {ROOT_LINE_LIMIT}. Move a section to the AGENTS.md of its folder.")
    for name in sorted(external - used):
        failures += 1
        print(f"{EXTERNAL}: `{name}`: no AGENTS.md names it")
    if failures:
        print(f"{failures} names in AGENTS.md files are not in the tree.", file=sys.stderr)
        return 1
    print(f"Checked {len(agents)} AGENTS.md files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
