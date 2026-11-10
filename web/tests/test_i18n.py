"""The interface language: the string tables, their use in the markup and the scripts, and the Korean text kept to one file.

The page's text comes from two tables (static/i18n-en.js, the source of truth for every key, and static/i18n-ko.js, Korean only,
every character written as a \\u escape) through `tl()` in static/i18n.js and the data-i18n attributes of the markup. Held here, with
no browser:

- every key a script or a page names (tl, tx, a data-i18n attribute, a key in a script's table) is in the English table, and every
  English key is used by something (a key left behind is a string nobody reads and nobody translates);
- the Korean table has every key the English one has: none missing, none empty, none left in English, none the English table lacks,
  and the same {name} placeholders in both; a key with a count has the plural forms English needs and the one form Korean needs;
- the words the markup carries are the English table's words for the key it names (the markup is what shows before a script runs);
- the Korean text is in i18n-ko.js alone, written as escapes: no other file of the shipped page, the docs or these tests holds a
  Hangul character (read as bytes), and i18n-ko.js itself is ASCII;
- the lookup (i18n.js) and the age words (shared.js relTime) run in node in both languages, with the fallbacks (a Korean key
  missing falls back to English, a key missing from both shows the key);
- the page and the terminal page are served with the saved language in <html lang>, and the scripts load in the order the lookup needs.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from html.parser import HTMLParser
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from i18n_node import STATIC, prelude
from sala_web.app import create_app
from sala_web.config import Settings

NODE = shutil.which("node")
needs_node = pytest.mark.skipif(not NODE, reason="node is not installed")
REPO = Path(__file__).resolve().parents[2]
HANGUL = re.compile("[" + "".join(f"{chr(a)}-{chr(b)}" for a, b in ((0x1100, 0x11FF), (0x3130, 0x318F), (0xAC00, 0xD7A3), (0xA960, 0xA97F), (0xD7B0, 0xD7FF))) + "]")
# scripts that are not the page's own text: the color tool is a pinned shared file (English), timing-debug.js a developer tool
NOT_TEXT = {"colortool.js", "timing-debug.js", "sw.js"}


def table(name: str) -> dict[str, str]:
    src = (STATIC / name).read_text()
    body = src[src.index("{", src.index("window.")):src.rindex("}") + 1]
    return json.loads(body)


EN = table("i18n-en.js")
KO = table("i18n-ko.js")
PLACEHOLDER = re.compile(r"\{(\w+)\}")


def holders(text: str) -> set[str]:
    return set(PLACEHOLDER.findall(text))


def base(key: str) -> str:
    return key[:-4] if key.endswith(".one") else key[:-6] if key.endswith(".other") else key


def page_files() -> list[Path]:
    return sorted(p for p in STATIC.iterdir() if p.suffix in (".js", ".html") and not p.name.startswith("i18n-")
                  and p.name not in NOT_TEXT)


def used_keys() -> dict[str, set[str]]:
    """Every key a page file names: a quoted token that starts with a table's first segment and has no file extension."""
    firsts = sorted({k.split(".")[0] for k in EN}, key=len, reverse=True)
    rx = re.compile(r"""["'`]((?:%s)\.[A-Za-z0-9_.]*[A-Za-z0-9_])["'`]""" % "|".join(map(re.escape, firsts)))
    out: dict[str, set[str]] = {}
    for p in page_files():
        for m in rx.finditer(p.read_text()):
            if re.search(r"\.(?:js|css|html|json|png|svg|tsv|txt|sh)$", m.group(1)):
                continue
            out.setdefault(m.group(1), set()).add(p.name)
    return out


def has_key(t: dict[str, str], key: str) -> bool:
    return key in t or key + ".one" in t or key + ".other" in t


def test_every_key_the_pages_name_is_in_the_english_table_and_every_english_key_is_used():
    used = used_keys()
    assert used, "no key found: the pattern in this test no longer matches how the scripts name keys"
    missing = {k: sorted(v) for k, v in used.items() if not has_key(EN, k)}
    assert not missing, f"keys named in a page file but not in static/i18n-en.js: {missing}"
    unused = sorted(k for k in EN if not any(k == u or k in (u + ".one", u + ".other") for u in used))
    assert not unused, f"keys in static/i18n-en.js that no page file names (delete them, or name them): {unused}"


def test_the_korean_table_has_every_key_with_the_same_placeholders_and_no_english_left_in_it():
    problems: list[str] = []
    for key, en in EN.items():
        want = key[:-4] + ".other" if key.endswith(".one") else key
        ko = KO.get(want)
        if ko is None:
            problems.append(f"{key}: missing from static/i18n-ko.js (as {want})")
            continue
        if not ko.strip():
            problems.append(f"{want}: empty")
        elif not re.search("[A-Za-z]", PLACEHOLDER.sub("", en)):
            pass   # nothing but placeholders (a count and a word the caller passes): there is no English in it to translate
        elif not HANGUL.search(ko) and ko.strip() != en.strip():
            problems.append(f"{want}: no Korean in it and not the English either: {ko!r}")
        elif ko.strip() == en.strip() and en not in ALLOWED_SAME:
            problems.append(f"{want}: the same as the English ({en!r}); if that is right, list it in ALLOWED_SAME")
        if not key.endswith(".one") and holders(ko) != holders(en):
            problems.append(f"{want}: placeholders {sorted(holders(ko))} differ from the English {sorted(holders(en))}")
    for key in KO:
        if not has_key(EN, base(key)):
            problems.append(f"{key}: in static/i18n-ko.js but not in static/i18n-en.js")
        if key.endswith(".one"):
            problems.append(f"{key}: Korean has the one plural form, \"<key>.other\"")
    assert not problems, "\n".join(problems)


# words that read the same in both languages (a term both languages keep as it is)
ALLOWED_SAME: set[str] = {"cron"}


def test_a_key_with_a_count_has_the_plural_forms_each_language_needs():
    for key in EN:
        if key.endswith(".one"):
            assert key[:-4] + ".other" in EN, f"{key}: English needs both forms"
            assert holders(EN[key[:-4] + ".other"]), f"{key}: the many form carries the count"


class Markup(HTMLParser):
    """The elements that carry data-i18n, data-i18n-title, -placeholder or -aria-label, with their text and the {arg} they name."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.items: list[tuple[str, str, str, str | None, str]] = []   # (kind, key, where, arg, text)
        self.stack: list[dict] = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        arg = a.get("data-i18n-arg")
        for kind, attr in (("title", "data-i18n-title"), ("placeholder", "data-i18n-placeholder"), ("aria-label", "data-i18n-aria-label"), ("word", "data-i18n-word")):
            if attr in a:
                self.items.append((kind, a[attr], tag, arg, a.get("data-word" if kind == "word" else kind, "")))
        if tag in ("br", "img", "input", "meta", "link", "hr"):
            return
        self.stack.append({"tag": tag, "key": a.get("data-i18n"), "arg": arg, "text": ""})

    def handle_endtag(self, tag):
        while self.stack:
            top = self.stack.pop()
            if top["key"]:
                self.items.append(("text", top["key"], top["tag"], top["arg"], top["text"]))
            if top["tag"] == tag:
                break

    def handle_data(self, data):
        for s in self.stack:
            if s["key"]:
                s["text"] += data


def markup_items(name: str) -> list[tuple[str, str, str, str | None, str]]:
    p = Markup()
    p.feed((STATIC / name).read_text())
    return p.items


def fill(text: str, arg: str | None) -> str:
    return text.replace("{arg}", arg) if arg is not None else text


@pytest.mark.parametrize("name", ["index.html", "terminal.html"])
def test_the_words_in_the_markup_are_the_english_tables_words_for_the_key_it_names(name):
    items = markup_items(name)
    if name == "index.html":
        assert len(items) > 100, "the page's text is not marked for translation any more"
    bad = []
    for kind, key, tag, arg, text in items:
        if key not in EN:
            bad.append(f"<{tag}> {kind}: {key} is not in the English table")
            continue
        want = " ".join(fill(EN[key], arg).split())
        got = " ".join(text.split())
        if got != want:
            bad.append(f"<{tag}> {kind} {key}: the markup says {got!r}, the table says {want!r}")
    assert not bad, "\n".join(bad)


def test_the_scripts_load_in_the_order_the_lookup_needs():
    html = (STATIC / "index.html").read_text()
    order = [html.index(f'src="static/{n}') for n in ("i18n-en.js", "i18n-ko.js", "i18n.js", "shared.js")]
    assert order == sorted(order), "i18n-en.js, i18n-ko.js, i18n.js, then shared.js"
    for later in ("sessions.js", "schedules.js", "machines.js", "search.js", "usage.js", "app.js"):
        assert html.index('src="static/i18n.js') < html.index(f'src="static/{later}'), later
    term = (STATIC / "terminal.html").read_text()
    assert term.index('src="static/i18n.js') < term.index('src="static/termclip.js') < term.index('src="static/terminal.js')


def test_the_korean_text_is_in_one_file_written_as_escapes_and_no_other_file_holds_hangul():
    ko = (STATIC / "i18n-ko.js").read_bytes()
    assert ko.isascii(), "static/i18n-ko.js must hold Korean as \\u escapes only"
    assert b"\\u" in ko
    text = {".py", ".js", ".html", ".css", ".md", ".json", ".txt", ".toml", ".tsv", ".svg", ".webmanifest"}
    shipped = [p for p in (REPO / "web" / "src").rglob("*") if p.is_file() and p.name != "i18n-ko.js" and p.suffix in text]
    docs = [p for p in (REPO / "docs").rglob("*.md")] + [REPO / "README.md", REPO / "web" / "README.md"]
    mine = [Path(__file__), STATIC.parents[2] / "tests" / "i18n_node.py", Path(__file__).with_name("test_i18n_browser.py")]
    for p in shipped + docs + mine:
        if not p.is_file():
            continue
        data = p.read_bytes().decode("utf-8", errors="replace")
        m = HANGUL.search(data)
        assert not m, f"{p.relative_to(REPO)} holds a Hangul character ({m.group(0)!r}): write Korean in static/i18n-ko.js as \\u escapes"


def test_the_english_table_is_not_empty_anywhere():
    for key, text in EN.items():
        assert text.strip(), key


# ── the lookup and the age words, run in node ──────────────────────────────────────────────────────────────────────

def run_node(program: str) -> object:
    out = subprocess.run([NODE, "-e", program], capture_output=True, text=True, check=True, timeout=60).stdout
    return json.loads(out)


@needs_node
def test_the_lookup_fills_placeholders_picks_the_plural_form_and_falls_back_in_order():
    prog = prelude("en") + r"""
const out = {};
out.fill = tl("app.ns.step.agent", { name: "x-y" });
out.one = tl("time.day", { n: 1 }); out.many = tl("time.day", { n: 3 });
out.missingKey = tl("no.such.key");
out.missingVar = tl("app.ns.step.agent", {});
SalaI18n.tables.ko["only.korean"] = "k"; SalaI18n.tables.en["only.english"] = "e";
SalaI18n.setLang("ko");
out.lang = SalaI18n.lang; out.locale = SalaI18n.locale();
out.koFill = tl("app.ns.step.agent", { name: "x-y" });
out.koPlural = [tl("time.day", { n: 1 }), tl("time.day", { n: 3 })];
out.fallback = tl("only.english"); out.koMissing = tl("no.such.key");
SalaI18n.setLang("fr"); out.back = SalaI18n.lang;
console.log(JSON.stringify(out));
"""
    got = run_node(prog)
    assert got["fill"] == "Add x-y to the project"
    assert got["one"] == "1 day ago" and got["many"] == "3 days ago"
    assert got["missingKey"] == "no.such.key" and got["missingVar"] == "Add {name} to the project"
    assert got["lang"] == "ko" and got["locale"] == "ko-KR"
    assert "x-y" in got["koFill"] and got["koFill"] != got["fill"]
    assert got["koPlural"][0] == got["koPlural"][1].replace("3", "1") and got["koPlural"][0] != got["one"]   # one form, the count filled
    assert got["fallback"] == "e", "a key only English has falls back to English"
    assert got["koMissing"] == "no.such.key"
    assert got["back"] == "en", "a language the page does not know is English"


@needs_node
def test_relative_ages_and_the_updated_line_follow_the_language():
    shared = (STATIC / "shared.js").read_text()
    def ages(lang: str) -> dict:
        return run_node(prelude(lang) + shared + r"""
const now = 1760000000000; Date.now = () => now;
console.log(JSON.stringify({ now: relTime(now - 5000), min: relTime(now - 5 * 60000), hour: relTime(now - 2 * 3600000),
  day: relTime(now - 3 * 86400000), fresh: agoLine(now - 60000, 600000), stale: agoLine(now - 3600000 * 5, 600000) }));
""")
    en, ko = ages("en"), ages("ko")
    assert en == {"now": "just now", "min": "5 min ago", "hour": "2 hours ago", "day": "3 days ago",
                  "fresh": "updated 1 min ago", "stale": "as of 5 hours ago"}
    for k in en:
        assert ko[k] != en[k] and HANGUL.search(ko[k]), (k, ko[k])
    assert "5" in ko["min"] and "2" in ko["hour"] and "3" in ko["day"], ko


@needs_node
def test_the_wait_words_of_a_queued_start_follow_the_language():
    shared = (STATIC / "shared.js").read_text()
    def words(lang: str) -> list:
        return run_node(prelude(lang) + shared + r"""
console.log(JSON.stringify([nsWaitText("queued", ""), nsWaitText("queued", "Waiting behind 2 retires."), nsWaitText("running", ""),
                            nsLateText("queued"), nsLateText("running")]));
""")
    en, ko = words("en"), words("ko")
    assert en[1] == "Waiting behind 2 retires.", "the line sala sends is shown as it is, in either language"
    assert ko[1] == en[1]
    for i in (0, 2, 3, 4):
        assert ko[i] != en[i] and HANGUL.search(ko[i]), (i, ko[i])
    assert "queued" in en[3] and "running" in en[4]


# ── the served pages ───────────────────────────────────────────────────────────────────────────────────────────────

def client(tmp_path) -> TestClient:
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    return TestClient(create_app(Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                                          tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])))


def test_the_pages_are_served_in_the_saved_language(tmp_path):
    c = client(tmp_path)
    for path in ("/", "/terminal"):
        html = c.get(path).text
        assert '<html lang="en">' in html and "{{lang}}" not in html, path
    assert c.put("/api/prefs", json={"lang": "ko"}).json()["ok"]
    for path in ("/", "/terminal"):
        assert '<html lang="ko">' in c.get(path).text, path
    assert c.put("/api/prefs", json={"lang": "en"}).json()["ok"]
    assert '<html lang="en">' in c.get("/").text


def test_a_language_the_page_does_not_have_is_refused_and_changes_nothing(tmp_path):
    c = client(tmp_path)
    assert c.put("/api/prefs", json={"lang": "ko"}).json()["ok"]
    for bad in ("fr", "", "KO", 1, None, ["ko"]):
        r = c.put("/api/prefs", json={"lang": bad})
        assert r.status_code == 400, bad
    assert c.get("/api/prefs").json()["lang"] == "ko"
    assert '<html lang="ko">' in c.get("/").text


def test_every_static_file_the_pages_load_for_the_language_is_served(tmp_path):
    c = client(tmp_path)
    for name in ("i18n.js", "i18n-en.js", "i18n-ko.js"):
        r = c.get(f"/static/{name}")
        assert r.status_code == 200 and "javascript" in r.headers["content-type"], name
