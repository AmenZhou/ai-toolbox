#!/usr/bin/env python3
"""Check a report deck (one HTML file, 1920x1080 stage) against its spec file.

Usage:
  check_deck.py <deck.html> [--spec <spec.md>] [--hosts <file>] [--before <old.html>]
                [--no-browser] [--chrome <path>] [--shots <dir> [--slides 1,3]] [--work <dir>]
  check_deck.py --selftest

Static checks fail (exit 1) on: more than 10 main slides; wrong counters; a link to a missing
or wrong slide; an index that does not match the titles; duplicate titles or edit keys; numbers
on a main slide the spec does not allow; a number in the deck that is not in the spec; a banned
pattern; a listed host (counts only, never the host); a missing spec section; with --before, a
slide whose text changed but whose edit key did not. Browser checks (headless Chrome, if found)
measure text overflow and overlap. Standard library only.
"""
import argparse
import html
import json
import re
import subprocess
import sys
import tempfile
from html.parser import HTMLParser
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKIP_CLASSES = {"chrome", "foot", "cover-top", "cover-foot"}
VOID = {"br", "img", "link", "meta", "hr", "input", "source", "wbr"}
CHROMES = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
           "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser"]
# Patterns that should stay off the slides unless the spec says otherwise (spec section 5).
BANNED = {
    "task id": r"\b20\d{6}-\d{6}\b",
    "ticket number": r"\b[A-Z]{2,}[-_]\d+\b|\b[A-Z]{2,}_[A-Z]+\d+\b",
    "merge request": r"\b(?:MR|PR)\s?[!#]\d+|![0-9]{3,}|[Mm]erge request",
    "adapter": r"\b[Aa]dapter\b",
    "prompt version": r"\bprompt[- ]v\d+\b",
    "web address": r"https?://|\bwww\.",
}
NORM = lambda s: re.sub(r"\s+", " ", s).strip()  # noqa: E731


class Deck(HTMLParser):
    """Collects, per slide: classes, edit key, label, counters, titles, links and text."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.slides, self.stack, self.cur, self.pos = [], [], None, ""
        self.link, self.p, self.cap = None, None, None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = set((a.get("class") or "").split())
        if a.get("id") == "pos":
            self.cap = ("pos", [])
        if tag == "section" and "slide" in cls:
            self.cur = dict(cls=cls, key=a.get("data-edit-key", ""), label=a.get("aria-label", ""), count="",
                            sect="", titles=[], links=[], ps=[], body=[], alltext=[], covercount="")
            self.slides.append(self.cur)
        if tag not in VOID:
            self.stack.append((tag, cls))
        if self.cur is None:
            return
        if tag == "a" and a.get("href", "").startswith("#"):
            self.link = dict(href=a["href"], text=[], b=[])
        if tag == "p":
            self.p = dict(text=[], hrefs=[])
        if self.link is not None and self.p is not None and tag == "a":
            self.p["hrefs"].append(a.get("href", ""))
        if "count" in cls or "sect" in cls or tag in ("h1", "h2"):
            self.cap = ("count" if "count" in cls else "sect" if "sect" in cls else tag, [])

    def handle_endtag(self, tag):
        if tag == "section" and self.cur is not None:
            self.cur = None
        while self.stack:
            t, _ = self.stack.pop()
            if t == tag:
                break
        if self.cur is None:
            if self.cap and self.cap[0] == "pos":
                self.pos = NORM("".join(self.cap[1]))
                self.cap = None
            return
        if tag == "a" and self.link is not None:
            self.link["text"] = NORM("".join(self.link["text"]))
            self.link["b"] = NORM("".join(self.link["b"]))
            self.cur["links"].append(self.link)
            self.link = None
        if tag == "p" and self.p is not None:
            self.cur["ps"].append(dict(text=NORM("".join(self.p["text"])), hrefs=self.p["hrefs"]))
            self.p = None
        if self.cap and (self.cap[0] in ("count", "sect") and tag == "span" or self.cap[0] == tag):
            kind, buf = self.cap
            s = NORM("".join(buf))
            if kind == "count":
                self.cur["count"] = s
            elif kind == "sect":
                self.cur["sect"] = s
            else:
                self.cur["titles"].append(s)
            self.cap = None

    def handle_data(self, data):
        if self.cap:
            self.cap[1].append(data)
        if self.cur is None:
            return
        in_skip = any(c & SKIP_CLASSES for _, c in self.stack)
        self.cur["alltext"].append(data)
        if re.fullmatch(r"\s*\d\d / \d\d\s*", data) and any("cover-foot" in c for _, c in self.stack):
            self.cur["covercount"] = NORM(data)
        if self.link is not None:
            in_b = any(t == "b" for t, _ in self.stack)
            self.link["b" if in_b else "text"].append(data)
        if self.p is not None:
            self.p["text"].append(data)
        if not in_skip and not any("count" in c or "sect" in c for _, c in self.stack):
            self.cur["body"].append(data)


def parse(path):
    d = Deck()
    d.feed(Path(path).read_text())
    for s in d.slides:
        s["body"], s["alltext"] = NORM(" ".join(s["body"])), NORM(" ".join(s["alltext"]))
    return d


def toks(s):
    return set(re.findall(r"[a-z0-9]+", s.lower())) - {"the", "a", "of", "and", "to", "in", "on", "for", "we"}


def similar(a, b):
    x, y = toks(a), toks(b)
    return bool(x and y) and len(x & y) / min(len(x), len(y)) >= 0.6


def matches_slide(text, s):
    return any(similar(text, c) for c in [s["sect"], s["label"], *s["titles"]] if c)


def numbers(text):
    """Numbers worth tracing: 2+ digits, decimals, or percentages. Dates, labels and phase/slide numbers are dropped."""
    for pat in (r"\d{4}-\d{2}-\d{2}", r"\d\d:\d\d", r"\bA\d+(?:\s*[–-]\s*A?\d+)?\b", r"\b[Pp]hases?\s+\d+(?:\s*[–-]\s*\d+)?",
                r"\b[Ss]lides?\s+\d+(?:\s*[–-]\s*\d+)?", r"\b[Ss]teps?\s+\d+(?:\s*[–-]\s*\d+)?", r"\b0\d\b", r"\bv\d+\b",
                r"\b(?:19|20)\d{2}\b"):
        text = re.sub(pat, " ", text)
    out = []
    for m in re.finditer(r"(?<![\w.])(\d[\d,]*(?:\.\d+)?)(%?)", text):
        n = m[1].replace(",", "")
        if len(n.replace(".", "")) >= 2 or "." in n or m[2]:
            out.append(n)
    return out


def spec_numbers(spec):
    return {m.replace(",", "") for m in re.findall(r"\d[\d,]*(?:\.\d+)?", spec)}


def allowed_main(spec):
    """Main slides that may show numbers. A line 'Main slides that may show numbers: 6, 2'; reference-spec wording as a fallback."""
    m = re.search(r"Main slides that may show numbers:\s*([\d,\s]*)", spec, re.I)
    if m:
        return {int(x) for x in re.findall(r"\d+", m[1])}
    found = set()
    for pat in (r"Only the slide[^.(]*\(slide (\d+)\)", r"made-up examples on slide (\d+)"):
        found |= {int(x) for x in re.findall(pat, spec)}
    return found


def banned_patterns(spec):
    pats = dict(BANNED)
    m = re.search(r"^Banned patterns:\s*(.+)$", spec, re.M | re.I)
    if m:
        for i, p in enumerate(x.strip() for x in m[1].split(" || ") if x.strip()):
            pats[f"spec pattern {i + 1}"] = p
    return pats


def static_checks(deck, spec, hosts_file=None, before=None):
    F = []  # (rule, detail)
    S = deck.slides
    total = len(S)
    div = next((i for i, s in enumerate(S) if s["label"] == "Appendix" or re.fullmatch(r"A\d+\s*[–-]\s*A\d+", s["count"])), None)
    if div is None:
        return [("structure", "no appendix divider found (label 'Appendix' or a count like A1–A3)")], {}
    M, N = div, total - div - 1
    if M > 10:
        F.append(("main-count", f"{M} main slides; the limit is 10. Merge two or move one to the appendix"))
    # counters
    for k in range(1, M + 1):
        s = S[k - 1]
        want = f"{k:02d} / {M:02d}"
        got = s["covercount"] if k == 1 and s["covercount"] else s["count"]
        if got != want:
            F.append(("counter", f"main slide {k}: counter reads '{got}', expected '{want}'"))
    if S[div]["count"] != f"A1–A{N}":
        F.append(("counter", f"divider reads '{S[div]['count']}', expected 'A1–A{N}'"))
    for j in range(1, N + 1):
        s = S[div + j]
        if s["count"] != f"A{j} / A{N}":
            F.append(("counter", f"appendix slide A{j}: counter reads '{s['count']}', expected 'A{j} / A{N}'"))
    if deck.pos and deck.pos != f"01 / {total:02d}":
        F.append(("counter", f"controller starts at '{deck.pos}', expected '01 / {total:02d}'"))
    # links: text 'An' (or 'An–Am') must open appendix slide n, which is slide M + 1 + n
    for i, s in enumerate(S, 1):
        for L in s["links"]:
            tgt = int(L["href"][1:]) if L["href"][1:].isdigit() else -1
            if not 1 <= tgt <= total:
                F.append(("link", f"slide {i}: link '{L['text']}' goes to missing slide {L['href']}"))
                continue
            m = re.fullmatch(r"A(\d+)(?:\s*[–-]\s*A?\d+)?", L["text"])
            if m and tgt != M + 1 + int(m[1]):
                F.append(("link", f"slide {i}: link '{L['text']}' opens slide {tgt}, expected {M + 1 + int(m[1])}"))
    # cover index: rows in order, each pointing at the slide it names
    rows = [(L["b"], L["text"], int(L["href"][1:])) for L in S[0]["links"] if L["b"] and L["href"][1:].isdigit()]
    want_nums = [str(k) for k in range(2, M + 1)] + ["A"]
    if [r[0] for r in rows] != want_nums:
        F.append(("index", f"cover index lists {[r[0] for r in rows]}, expected {want_nums}"))
    for b, text, tgt in rows:
        k = M + 1 if b == "A" else int(b) if b.isdigit() else -1
        if tgt != k:
            F.append(("index", f"cover index row '{b}' opens slide {tgt}, expected {k}"))
        elif 1 <= tgt <= total and b != "A" and not matches_slide(text, S[tgt - 1]):
            F.append(("index", f"cover index row {b} '{text}' does not match the title of slide {tgt}"))
    # divider index
    for p in S[div]["ps"]:
        m = re.match(r"A(\d+)\s+(.*)", p["text"])
        if not m or not p["hrefs"]:
            continue
        n, title = int(m[1]), m[2]
        if p["hrefs"][0] != f"#{M + 1 + n}":
            F.append(("index", f"divider row A{n} opens {p['hrefs'][0]}, expected #{M + 1 + n}"))
        elif n <= N and not matches_slide(title, S[div + n]):
            F.append(("index", f"divider row A{n} '{title}' does not match the title of slide A{n}"))
    listed = {int(re.match(r"A(\d+)", p["text"])[1]) for p in S[div]["ps"] if re.match(r"A(\d+)\s", p["text"])}
    if listed != set(range(1, N + 1)):
        F.append(("index", f"divider lists A{sorted(listed)}, expected A1..A{N}"))
    # titles and edit keys
    seen = {}
    for i, s in enumerate(S, 1):
        t = NORM(re.sub(r"[^\w ]", "", (s["titles"] or [""])[0].lower()))
        if t and t in seen and 1 < i != div + 1:
            F.append(("duplicate", f"slide {i} has the same title as slide {seen[t]}"))
        seen.setdefault(t, i)
    keys = {}
    for i, s in enumerate(S, 1):
        if not s["key"]:
            F.append(("edit-key", f"slide {i} has no data-edit-key"))
        elif s["key"] in keys:
            F.append(("edit-key", f"slide {i} repeats the edit key of slide {keys[s['key']]}"))
        keys.setdefault(s["key"], i)
    # spec sections, numbers, banned patterns
    have = {int(x) for x in re.findall(r"^##\s+(\d+)\.", spec, re.M)}
    if miss := sorted(set(range(1, 12)) - have):
        F.append(("spec", f"spec sections missing: {miss}"))
    allow = allowed_main(spec)
    known = spec_numbers(spec)
    for i, s in enumerate(S, 1):
        ns = numbers(s["body"])
        if i <= M and ns and i not in allow:
            F.append(("numbers-main", f"main slide {i} shows {len(ns)} number(s); the spec allows numbers on slides {sorted(allow) or 'none'}"))
        if bad := [n for n in ns if n not in known]:
            F.append(("numbers-spec", f"slide {i}: {len(bad)} number(s) not in the spec: {sorted(set(bad))[:6]}"))
    for name, pat in banned_patterns(spec).items():
        hit = [i for i, s in enumerate(S, 1) if re.search(pat, s["alltext"])]
        if hit:
            F.append(("banned", f"'{name}' found on slide(s) {hit}"))
    if hosts_file:
        hosts = {h.strip().lower() for h in Path(hosts_file).read_text().splitlines() if h.strip() and not h.startswith("#")}
        n = sum(1 for h in hosts if any(h in s["alltext"].lower() for s in S))
        if n:
            F.append(("host", f"{n} of {len(hosts)} listed host(s) found in the deck"))
    if before:
        old = {s["key"]: s["body"] for s in parse(before).slides}
        for i, s in enumerate(S, 1):
            if s["key"] in old and old[s["key"]] != s["body"]:
                F.append(("edit-key-stale", f"slide {i}: text changed but data-edit-key '{s['key']}' did not"))
    return F, dict(slides=total, main=M, appendix=N, allowed=sorted(allow))


MEASURE_JS = r"""<script>
window.addEventListener('load', () => setTimeout(() => {
  const slides = [...document.querySelectorAll('.slide')];
  slides.forEach(s => { s.classList.add('visible'); s.style.visibility = 'visible'; s.style.opacity = '1'; });
  setTimeout(() => {
    const sr = document.getElementById('deckStage').getBoundingClientRect(), f = sr.width / 1920, out = [];
    const R = e => { const r = e.getBoundingClientRect(); return {l:(r.left-sr.left)/f, t:(r.top-sr.top)/f, r:(r.right-sr.left)/f, b:(r.bottom-sr.top)/f}; };
    const nm = e => e.tagName.toLowerCase() + (e.className && typeof e.className === 'string' ? '.' + e.className.split(' ')[0] : '');
    slides.forEach((s, i) => {
      const add = (type, e) => out.push({slide: i + 1, type, el: nm(e)});
      const reg = s.querySelector('.body-region'), ch = s.querySelector('.chrome'), ft = s.querySelector('.foot');
      if (reg && reg.scrollHeight > reg.clientHeight + 2) add('region taller than its space', reg);
      const leaves = [];
      s.querySelectorAll('*').forEach(e => {
        if (e === s || e.classList.contains('pad')) return;
        const r = R(e); if (r.r - r.l < 1 || r.b - r.t < 1) return;
        if (r.r > 1921 || r.b > 1081 || r.l < -1 || r.t < -1) add('outside the slide', e);
        if (e.clientWidth > 0 && e.scrollWidth > e.clientWidth + 2) add('text wider than its box', e);
        const own = [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
        if (own && getComputedStyle(e).display !== 'inline') leaves.push([e, r]);  // inline text wraps: its box spans lines
        if (reg && reg.contains(e) && own) {
          if (ft && r.b > R(ft).t + 1) add('overlaps the footer', e);
          if (ch && r.t < R(ch).b - 1) add('overlaps the header', e);
        }
      });
      for (let a = 0; a < leaves.length; a++) for (let b = a + 1; b < leaves.length; b++) {
        const [x, p] = leaves[a], [y, q] = leaves[b];
        if (x.contains(y) || y.contains(x)) continue;
        const w = Math.min(p.r, q.r) - Math.max(p.l, q.l), h = Math.min(p.b, q.b) - Math.max(p.t, q.t);
        if (w > 3 && h > 3) add('text overlaps other text', x);
      }
    });
    const pre = document.createElement('pre'); pre.id = '__m'; pre.textContent = JSON.stringify(out); document.body.appendChild(pre);
  }, 1500);
}, 300));
</script>"""


def find_chrome(arg=None):
    for c in ([arg] if arg else []) + CHROMES:
        if c and Path(c).exists():
            return c
    return None


def run_chrome(chrome, work, *args, timeout=120):
    cmd = [chrome, "--headless=new", "--disable-gpu", f"--user-data-dir={work / 'chrome'}",
           "--window-size=1920,1080", "--virtual-time-budget=6000", *args]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def browser_checks(deck_path, chrome, work):
    work.mkdir(parents=True, exist_ok=True)
    src = Path(deck_path).read_text()
    probe = work / "measure.html"
    probe.write_text(src.replace("</body>", MEASURE_JS + "\n</body>"))
    r = run_chrome(chrome, work, "--dump-dom", probe.as_uri())
    m = re.search(r'<pre id="__m">(.*?)</pre>', r.stdout, re.S)
    if not m:
        return [("browser", "the measurement did not run (Chrome gave no result)")]
    issues = json.loads(html.unescape(m[1]))
    seen, out = set(), []
    for x in issues:
        k = (x["slide"], x["type"], x["el"])
        if k not in seen:
            seen.add(k)
            out.append(("layout", f"slide {x['slide']}: {x['type']} ({x['el']})"))
    return out


def shots(deck_path, chrome, work, outdir, which, total):
    outdir.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    for n in which or range(1, total + 1):
        png = outdir / f"slide-{n:02d}.png"
        run_chrome(chrome, work, f"--screenshot={png}", Path(deck_path).resolve().as_uri() + f"#{n}")
        print(f"shot {png}")


def check(deck_path, spec_path, hosts=None, before=None, use_browser=True, chrome_arg=None, work=None):
    deck = parse(deck_path)
    spec = Path(spec_path).read_text()
    F, info = static_checks(deck, spec, hosts, before)
    note = None
    if use_browser:
        chrome = find_chrome(chrome_arg)
        if chrome:
            F += browser_checks(deck_path, chrome, work)
            note = "browser check: ran (overflow and overlap measured)"
        else:
            note = "SKIP browser checks: no Chrome found. Overflow and overlap are NOT measured; do not say the slides fit"
    return F, info, note


# ---------------------------------------------------------------- selftest
def selftest():
    tpl = (HERE.parent / "assets" / "template.html").read_text()
    spec = (HERE.parent / "assets" / "spec-template.md").read_text()
    s05 = re.search(r'<section class="slide light" data-edit-key="s05".*?</section>\n', tpl, re.S)[0]
    cases = [  # (name, expected rule, mutate deck, mutate spec)
        ("good", None, lambda t: t, lambda s: s),
        ("11 main slides", "main-count", lambda t: t.replace(s05, s05 * 3), lambda s: s),
        ("wrong counter", "counter", lambda t: t.replace("03 / 09", "03 / 08"), lambda s: s),
        ("link to missing slide", "link", lambda t: t.replace('href="#12">A2', 'href="#99">A2', 1), lambda s: s),
        ("link to wrong slide", "link", lambda t: t.replace('href="#12">A2', 'href="#13">A2', 1), lambda s: s),
        ("index does not match", "index", lambda t: t.replace("</b>Why herbs fail</a>", "</b>Zebra crossing quartz</a>"), lambda s: s),
        ("duplicate title", "duplicate", lambda t: t.replace("Light decided the result; <em>a lamp helped most</em>.", "Light from the sun <em>is not enough alone</em>."), lambda s: s),
        ("duplicate edit key", "edit-key", lambda t: t.replace('data-edit-key="s03"', 'data-edit-key="s02"'), lambda s: s),
        ("number on a main slide", "numbers-main", lambda t: t.replace("Fewer pots rotted. Growth", "Fewer pots rotted: 75%. Growth"), lambda s: s),
        ("number not in the spec", "numbers-spec", lambda t: t.replace(">92%</span>", ">93%</span>", 1), lambda s: s),
        ("banned task id", "banned", lambda t: t.replace("Most people lose", "Task 20261124-171208 says most people lose"), lambda s: s),
        ("listed host", "host", lambda t: t.replace("Most people lose", "See evil.example. Most people lose"), lambda s: s),
        ("spec section missing", "spec", lambda t: t, lambda s: re.sub(r"^## 5\..*$", "", s, flags=re.M)),
        ("text too long", "layout", lambda t: t.replace("Four steps: <em>each answer raised the next question</em>.", "Four steps " + "and one more long clause " * 30), lambda s: s),
    ]
    chrome = find_chrome()
    bad = 0
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "hosts.txt").write_text("evil.example\n")
        for name, rule, md, ms in cases:
            if rule == "layout" and not chrome:
                print(f"skip {name}: no Chrome")
                continue
            (d / "deck.html").write_text(md(tpl))
            (d / "spec.md").write_text(ms(spec))
            F, _, _ = check(d / "deck.html", d / "spec.md", d / "hosts.txt", use_browser=bool(chrome), chrome_arg=None, work=d / "w")
            got = {r for r, _ in F}
            ok = (not got) if rule is None else (rule in got)
            bad += not ok
            print(f"{'ok  ' if ok else 'FAIL'} {name}: {sorted(got) or 'no problems'}")
        # --spec-only: the shipped spec template is clean; each broken variant is caught
        for name, ms in [("spec only, good", lambda s: s), ("spec only, no numbers line", lambda s: s.replace("Main slides that may show numbers: 6", "")),
                         ("spec only, bad regex", lambda s: s.replace("Banned patterns: ", "Banned patterns: ([ || ")),
                         ("spec only, no status", lambda s: s.replace("status: draft", ""))]:
            P = spec_problems(ms(spec))
            ok = (not P) if name.endswith("good") else bool(P)
            bad += not ok
            print(f"{'ok  ' if ok else 'FAIL'} {name}: {[m for _, m in P] or 'no problems'}")
        # --before: same key, changed text
        (d / "new.html").write_text(tpl.replace("Fewer pots rotted.", "Fewer pots rotted a lot."))
        (d / "old.html").write_text(tpl)
        F, _ = static_checks(parse(d / "new.html"), spec, None, d / "old.html")
        ok = "edit-key-stale" in {r for r, _ in F}
        bad += not ok
        print(f"{'ok  ' if ok else 'FAIL'} text changed, key not: {sorted({r for r, _ in F})}")
    return bad


def spec_problems(spec):
    """Spec-only checks, usable before any slide exists."""
    out = []
    if miss := sorted(set(range(1, 12)) - {int(x) for x in re.findall(r"^##\s+(\d+)\.", spec, re.M)}):
        out.append(("spec", f"sections missing: {miss}"))
    if not re.search(r"^status:\s*(draft|approved)\b", spec, re.M):
        out.append(("spec", "frontmatter needs 'status: draft' or 'status: approved'"))
    if not re.search(r"^Main slides that may show numbers:", spec, re.M | re.I):
        out.append(("spec", "no line 'Main slides that may show numbers: <list>' (write 'none' if no slide may)"))
    for i, p in enumerate(x.strip() for x in (re.search(r"^Banned patterns:\s*(.+)$", spec, re.M | re.I) or [None, ""])[1].split(" || ") if x.strip()):
        try:
            re.compile(p)
        except re.error as e:
            out.append(("spec", f"banned pattern {i + 1} is not a valid regex: {e}"))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("deck", nargs="?")
    ap.add_argument("--spec-only", metavar="SPEC", help="check a spec file alone, before any slide exists")
    ap.add_argument("--spec")
    ap.add_argument("--hosts")
    ap.add_argument("--before")
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("--chrome")
    ap.add_argument("--shots")
    ap.add_argument("--slides")
    ap.add_argument("--work", default=str(Path.home() / "apps/ai-console/tmp/sdd-create-deck"))
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(1 if selftest() else 0)
    if a.spec_only:
        P = spec_problems(Path(a.spec_only).expanduser().read_text())
        for rule, msg in P:
            print(f"FAIL {rule}: {msg}")
        print("PASS" if not P else f"{len(P)} problem(s)")
        sys.exit(1 if P else 0)
    if not a.deck:
        ap.error("give a deck, --spec-only <spec> or --selftest")
    deck = Path(a.deck).expanduser().resolve()
    spec = Path(a.spec).expanduser() if a.spec else deck.with_suffix(".spec.md")
    if not spec.exists():
        sys.exit(f"spec not found: {spec}")
    work = Path(a.work).expanduser()
    F, info, note = check(deck, spec, a.hosts, a.before, not a.no_browser, a.chrome, work)
    for rule, msg in F:
        print(f"FAIL {rule}: {msg}")
    if note:
        print(note)
    print(", ".join(f"{k} {v}" for k, v in info.items()))
    if a.shots:
        c = find_chrome(a.chrome)
        if not c:
            sys.exit("no Chrome found for --shots")
        which = [int(x) for x in a.slides.split(",")] if a.slides else None
        shots(deck, c, work, Path(a.shots).expanduser(), which, info["slides"])
    print("PASS" if not F else f"{len(F)} problem(s)")
    sys.exit(1 if F else 0)


if __name__ == "__main__":
    main()
