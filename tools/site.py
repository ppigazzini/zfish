"""Prepare docs/ for the site and hold the site's manifest to the docs.

Zensical builds the site from `mkdocs.yml` with `--strict`, which refuses a link to a
page that does not exist. These pages are written for a contributor reading the tree, so
they link into it -- `../src/...`, `../CONTRIBUTING.md` -- and on GitHub those links
resolve. On the site they would not, and Zensical runs no MkDocs hook to rewrite them. So
this copies `docs/` to `site-src/`, the directory `mkdocs.yml` builds, with every link
that leaves `docs/` rewritten to the file on GitHub at BRANCH. The pages keep their
relative links, which `docs-lint` checks against the tree.

Before it copies, it refuses a manifest apart from the docs: the `llmstxt` sections of
`mkdocs.yml` must list the nav's pages in the nav's order, and each page's line must be
the cell the index table in `docs/index.md` gives it in COLUMN. Zensical reads both lists as
written and checks neither against the other.

Exit codes:  0 prepared   1 the manifest is apart from the docs   2 could not run
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
OUT = ROOT / "site-src"
# The branch the site is built from; a link out of docs/ points at its file there.
BRANCH = "main"

# A link whose target leaves docs/: inline `](../x)`, and a reference definition.
INLINE = re.compile(r"\]\(\.\./([^)\s]+)\)")
REFDEF = re.compile(r"^(\[[^\]]+\]:[ \t]*)\.\./(\S+)", re.MULTILINE)
# The index table's column whose cell is a page's line in the manifest, and the link that
# opens each of its rows.
COLUMN = "Description"
PAGE = re.compile(r"\[[^\]]+\]\(([a-z0-9-]+\.md)\)")


class _Loader(yaml.SafeLoader):
    """Reads mkdocs.yml, whose Python tags name a formatter and a slug function."""


_Loader.add_multi_constructor("tag:yaml.org,2002:python/", lambda _l, _s, _n: None)


def nav_pages(nav: list) -> list[str]:
    pages: list[str] = []
    for entry in nav:
        value = next(iter(entry.values())) if isinstance(entry, dict) else entry
        if isinstance(value, list):
            pages.extend(nav_pages(value))
        else:
            pages.append(value)
    return pages


def manifest(config: dict) -> list[tuple[str, str]]:
    for plugin in config.get("plugins", []):
        if isinstance(plugin, dict) and "llmstxt" in plugin:
            lines: list[tuple[str, str]] = []
            for entries in plugin["llmstxt"]["sections"].values():
                for entry in entries:
                    if isinstance(entry, dict):
                        (page, text), *_ = entry.items()
                        lines.append((page, text or ""))
                    else:
                        lines.append((entry, ""))
            return lines
    return []


def index_table() -> dict[str, str]:
    """Each page the index table lists, with its cell in COLUMN."""
    table: dict[str, str] = {}
    column: int | None = None
    for line in (DOCS / "index.md").read_text(encoding="utf-8").splitlines():
        if not line.startswith("|"):
            column = None
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if column is None:
            column = cells.index(COLUMN) if COLUMN in cells else None
            continue
        page = PAGE.fullmatch(cells[0])
        if page and column < len(cells):
            table[page.group(1)] = cells[column]
    return table


def check(config: dict) -> list[str]:
    problems: list[str] = []
    nav = nav_pages(config.get("nav", []))
    lines = manifest(config)
    if not lines:
        return ["mkdocs.yml: no llmstxt sections"]
    if [page for page, _ in lines] != nav:
        problems.append(
            "mkdocs.yml: the llmstxt sections do not list the nav's pages in its order\n"
            f"  nav:      {nav}\n  sections: {[page for page, _ in lines]}"
        )
    table = index_table()
    for page, text in lines:
        if page == "index.md":
            if not text:
                problems.append("mkdocs.yml: index.md has no llmstxt description")
            continue
        want = table.get(page)
        if want is None:
            problems.append(f"docs/index.md: {page} has no row in the index table")
        elif text != want:
            problems.append(
                f"mkdocs.yml: the llmstxt line for {page} is not its index-table {COLUMN}\n"
                f"  index:    {want}\n  mkdocs:   {text}"
            )
    on_disk = sorted(p.name for p in DOCS.glob("*.md"))
    if sorted(nav) != on_disk:
        problems.append(
            f"mkdocs.yml: the nav is not docs/*.md\n  nav: {sorted(nav)}\n  docs: {on_disk}"
        )
    return problems


def prepare(blob: str) -> int:
    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(DOCS, OUT)
    rewritten = 0
    for page in OUT.rglob("*.md"):
        text = page.read_text(encoding="utf-8")
        text, a = INLINE.subn(lambda m: f"]({blob}/{m.group(1)})", text)
        text, b = REFDEF.subn(lambda m: f"{m.group(1)}{blob}/{m.group(2)}", text)
        page.write_text(text, encoding="utf-8")
        rewritten += a + b
    return rewritten


def main() -> int:
    try:
        config = yaml.load((ROOT / "mkdocs.yml").read_text(encoding="utf-8"), Loader=_Loader)
    except (OSError, yaml.YAMLError) as error:
        print(f"site: could not read mkdocs.yml: {error}", file=sys.stderr)
        return 2
    problems = check(config)
    for problem in problems:
        print(f"site: {problem}")
    if problems:
        return 1
    blob = f"{config['repo_url'].rstrip('/')}/blob/{BRANCH}"
    count = prepare(blob)
    print(f"site: {OUT.name}/ prepared, {count} link(s) out of docs/ pointed at {blob}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
