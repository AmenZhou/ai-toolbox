#!/usr/bin/env python3
"""Check a folder of specs (README.md with a status table, plus spec files).

Usage:
  check_specs.py <spec-folder> [--vault <dir>] [--hosts <file>]
  check_specs.py --selftest

Fails (exit 1) on: duplicate ids, a reference to a missing id, a status the README
does not define, a broken [[wiki link]], a missing frontmatter field, a README table
row that links to a missing file, and (with --hosts) any listed host found in the
specs. It prints counts, never a host. Standard library only.
"""
import argparse
import re
import sys
import tempfile
from pathlib import Path

FRONTMATTER = ["title", "category", "tags", "sources", "created", "updated", "summary"]
ID = re.compile(r"[A-Z]-\d+")
REF = re.compile(r"\b([A-Z])-(\d+)\b")
LINK = re.compile(r"\[\[([^\]]+)\]\]")
ALWAYS_OK = {"withdrawn"}  # a dropped requirement keeps its row and id


def split_row(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def split_doc(text):
    """Return (frontmatter keys or None, body)."""
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---", 4)
    if end < 0:
        return None, text
    keys = set(re.findall(r"^([A-Za-z_]+):", text[4:end], re.M))
    return keys, text[end + 4:]


def table_rows(body):
    """Yield (header cells, row cells, raw line) for every data row of every table."""
    header = None
    lines = body.splitlines()
    for i, line in enumerate(lines):
        if not line.startswith("|"):
            header = None
            continue
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if header is None and re.match(r"^\|[\s:|-]+\|?\s*$", nxt):
            header = [c.lower() for c in split_row(line)]
        elif header is not None and not re.match(r"^\|[\s:|-]+\|?\s*$", line):
            yield header, split_row(line), line


def readme_statuses(body):
    for header, row, _ in table_rows(body):
        if header[:2] == ["status", "meaning"]:
            yield re.sub(r"[*`]", "", row[0]).strip().lower()


def find_vault(folder):
    for p in [folder, *folder.parents]:
        if p.name == "obsidian":
            return p
    return folder.parent


def link_ok(target, vault, folder):
    t = target.split("|")[0].split("#")[0].strip()
    if not t:
        return True
    return any((base / t).exists() or (base / (t + ".md")).exists() for base in (vault, folder))


def check(folder, vault, hosts_file=None):
    errors, counts = [], {}
    files = sorted(folder.glob("*.md"))
    readme = folder / "README.md"
    if not readme.exists():
        return [("no-readme", "README.md is missing")], counts
    docs = {f.name: split_doc(f.read_text()) for f in files}
    statuses = set(readme_statuses(docs["README.md"][1])) | ALWAYS_OK
    if len(statuses) == len(ALWAYS_OK):
        return [("no-status-table", "README.md has no | Status | Meaning | table")], counts

    ids, link_n = {}, 0
    for name, (keys, body) in docs.items():
        for k in FRONTMATTER:
            if keys is None or k not in keys:
                errors.append(("frontmatter", f"{name}: missing field '{k}'"))
        for header, row, _ in table_rows(body):
            first = row[0].replace("*", "").strip()
            if not ID.fullmatch(first):
                continue
            if first in ids:
                errors.append(("duplicate-id", f"{first} in {name} and {ids[first]}"))
            ids[first] = name
            if "status" in header and len(row) == len(header):
                # "not built" is the opposite of Built, so it must not count as a status word
                cell = re.sub(r"\bnot built\b", "", row[header.index("status")].lower())
                words = set(re.findall(r"[a-z]+", cell))
                if not words & statuses:
                    errors.append(("unknown-status", f"{first} in {name}"))

    prefixes = {i[0] for i in ids}
    for name, (_, body) in docs.items():
        seen = set()
        for m in REF.finditer(body):
            ref = f"{m[1]}-{m[2]}"
            if m[1] in prefixes and ref not in ids and ref not in seen:
                seen.add(ref)
                errors.append(("missing-id", f"{ref} referenced in {name}"))
        for line in body.splitlines():
            is_readme_row = name == "README.md" and line.startswith("| [[")
            for target in LINK.findall(line):
                link_n += 1
                if not link_ok(target, vault, folder):
                    rule = "readme-row" if is_readme_row else "broken-link"
                    errors.append((rule, f"{name}: [[{target.split('|')[0]}]]"))

    if hosts_file:
        hosts = {h.strip().lower() for h in Path(hosts_file).read_text().splitlines()
                 if h.strip() and not h.startswith("#")}
        for name in docs:
            text = (folder / name).read_text().lower()
            n = sum(1 for h in hosts if h in text)
            if n:  # count only: never print the host
                errors.append(("host-leak", f"{name}: {n} listed host(s) found"))
        counts["hosts checked"] = len(hosts)

    counts.update({"files": len(files), "ids": len(ids), "links": link_n,
                   "statuses": len(statuses - ALWAYS_OK)})
    return errors, counts


# ---------- selftest: made-up specs, one good and one bad per rule ----------
FM = ("---\ntitle: t\ncategory: c\ntags: [x]\nsources: [s]\n"
      "created: 2026-01-01\nupdated: 2026-01-01\nsummary: s\n---\n")
GOOD = {
    "README.md": FM + "| Status | Meaning |\n|---|---|\n| **Built** | in code |\n| **Open** | undecided |\n\n"
                 "| Spec | Answers |\n|---|---|\n| [[svc/01-a]] | a |\n",
    "01-a.md": FM + "| ID | Requirement | Status |\n|---|---|---|\n"
               "| A-1 | one | Built |\n| A-2 | two, see A-1 | **Open** |\n| A-3 | dropped | Withdrawn 2026-01-02 |\n",
}


def selftest():
    cases = {  # rule -> how to break GOOD
        "duplicate-id": lambda f: f.update({"01-a.md": f["01-a.md"] + "| A-1 | again | Built |\n"}),
        "missing-id": lambda f: f.update({"01-a.md": f["01-a.md"] + "\nSee A-9.\n"}),
        "unknown-status": lambda f: f.update({"01-a.md": f["01-a.md"] + "| A-4 | x | Maybe |\n"}),
        "unknown-status (not built)": lambda f: f.update({"01-a.md": f["01-a.md"] + "| A-4 | x | Not built |\n"}),
        "broken-link": lambda f: f.update({"01-a.md": f["01-a.md"] + "\n[[svc/nope]]\n"}),
        "frontmatter": lambda f: f.update({"01-a.md": f["01-a.md"].replace("summary: s\n", "")}),
        "readme-row": lambda f: f.update({"README.md": f["README.md"] + "| [[svc/02-gone]] | b |\n"}),
        "host-leak": lambda f: f.update({"01-a.md": f["01-a.md"] + "\nevil.example\n"}),
        "no-status-table": lambda f: f.update({"README.md": FM + "nothing\n"}),
    }
    failed = 0
    for rule in ["good", *cases]:
        files = dict(GOOD)
        if rule != "good":
            cases[rule](files)
        with tempfile.TemporaryDirectory() as d:
            vault = Path(d) / "obsidian"
            folder = vault / "svc"
            folder.mkdir(parents=True)
            for n, t in files.items():
                (folder / n).write_text(t)
            hosts = Path(d) / "hosts.txt"
            hosts.write_text("evil.example\n")
            errs, _ = check(folder, vault, hosts)
        got = {r for r, _ in errs}
        ok = (not got) if rule == "good" else (got == {rule.split(" ")[0]})
        failed += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {rule}: {sorted(got) or 'no errors'}")
    return failed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", nargs="?")
    ap.add_argument("--vault")
    ap.add_argument("--hosts")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(1 if selftest() else 0)
    if not a.folder:
        ap.error("give a spec folder or --selftest")
    folder = Path(a.folder).expanduser().resolve()
    vault = Path(a.vault).expanduser().resolve() if a.vault else find_vault(folder)
    errors, counts = check(folder, vault, a.hosts)
    for rule, msg in errors:
        print(f"FAIL {rule}: {msg}")
    print(", ".join(f"{k} {v}" for k, v in counts.items()) or "no counts")
    print("PASS" if not errors else f"{len(errors)} problem(s)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
