"""The color tool in sala: stackshot's shared file pinned byte for byte (static/colortool.js, its sha256 in static/colortool.js.sha256, pinned by
tools/pin-colortool), sala's own wiring (static/colortool-sala.js), and the button at the bottom of the side panel (#side-colors in index.html).

What a wrong answer costs: a pinned copy that was edited by hand or drifted from its sha file (the next pin would silently undo a local fix); a
script missing from one of the pages (the main page, /v2/, the full-size terminal), or loaded twice; a stored look that flashes on first paint
because it is applied after the body; a floating button back in the corner, or one that sits over the composer; a panel that does not fit a phone
or cannot be scrolled; a Fields fold that starts open or forgets whether it was left open; a Reset or "Live now" that leaves an inline property behind (the shifted surfaces, the disabled pair's opacity, the
status-bar color); a look stored by the earlier try-out (a flat map of the 14 keys under `sala-colortry`) that stops loading; the light theme
recolored by a dark pick; a saved list that breaks the panel when stackshot is away, or a token or sender label in the browser.

Text checks read the files; the browser checks drive a headless Chromium (the `served` and `browser` fixtures of conftest.py) at 360 and 1280 px
for the placement and 390 px for the picks. The saved list goes through sala's own routes to the fake stackshot (fake_stackshot.py); the real one
is never called. The routes themselves are in test_colors_combos.py. Not covered: a real phone's color picker dialog (the picker's `input` event is
dispatched by the test), the installed app's status bar (the theme-color meta is checked, the bar is not), the panel's own texts and layout inside
(stackshot's file, tested there), and how the colors look (by eye)."""

from __future__ import annotations

import hashlib
import importlib.machinery
import importlib.util
import json
import re
import shutil
import time
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from conftest import NAME
from fake_stackshot import FakeStackshot
from sala_web.app import STATIC, create_app
from sala_web.config import Settings
from test_theme_contrast import THEMES

TOOL = STATIC / "colortool.js"
WIRING = STATIC / "colortool-sala.js"
SHA = STATIC / "colortool.js.sha256"
PIN = STATIC.parent.parent.parent / "tools" / "pin-colortool"
SRC = '<script src="static/%s?v={{v}}"></script>'
INIT = "<script>if (window.SalaColors) SalaColors.init();</script>"

PAGES = [("main", "/"), ("v2", "/v2/"), ("terminal", "/terminal?arg=x")]
CHAT = f"#s={NAME}"
READY_CHAT = "typeof state !== 'undefined' && state.byName.has(%s) && document.querySelectorAll('#chat .msg').length > 0" % json.dumps(NAME)

KEYS = ["bg", "card", "line", "fg", "mut", "link", "ibd", "solid", "onsolid", "disbg", "disfg", "labbg", "labfg", "labbd"]
VARS = {"bg": ["--bg", "--side-bg"], "card": ["--panel"], "fg": ["--text"], "mut": ["--muted"], "line": ["--border"], "ibd": ["--faint"],
        "link": ["--link", "--call", "--accent", "--role-front-text", "--acc"], "solid": ["--accent-solid"], "onsolid": ["--accent-on-solid"],
        "labbg": ["--label-bg"], "labfg": ["--label-fg"], "labbd": ["--label-bd"], "disbg": ["--dis-bg"], "disfg": ["--dis-fg"]}
SHIFTED = ["--code-bg", "--hover", "--selected", "--user-bubble"]
OWN_VARS = [v for k in VARS for v in VARS[k]] + SHIFTED + ["--dis-op"]
DARK = THEMES["dark"]
META_DARK = DARK["--bg"]
# what the dark theme ships for the five fields that follow others (the shipped dark look);
# the light theme sets none of these tokens and keeps the stylesheets' fallbacks. The first four neutrals and the oranges are the dark theme's own tokens.
SHIPPED_LABELS = {"labbg": "#3a2619", "labfg": "#f0a06a", "labbd": "#3a2619", "disbg": "#2a2a2c", "disfg": "#a3a29d"}
SHIPPED_TOKENS = {"labbg": "--label-bg", "labfg": "--label-fg", "labbd": "--label-bd", "disbg": "--dis-bg", "disfg": "--dis-fg"}

# the earlier try-out's stored look: a flat map of #rrggbb under "sala-colortry"
OLD_LOOK = {"bg": "#1f1f21", "link": "#ffa057", "solid": "#c96442", "labbg": "#462100", "disbg": "#2a2a2c"}
# "Radix" without its neutrals (they equal the shipped values)
RADIX = {"link": "#ffa057", "solid": "#f76b15", "onsolid": "#ffffff", "labbg": "#462100", "labfg": "#ffa057", "labbd": "#462100",
         "disbg": "#2a2a2c", "disfg": "#a3a29d"}
# what the tool stores for it: no field equal to what it would be unset (the label text follows the link color)
RADIX_STORED = {k: v for k, v in RADIX.items() if k != "labfg"}


def rgb(h: str) -> list[int]:
    return [int(h[i:i + 2], 16) for i in (1, 3, 5)]


def shifted(base: str, pick: str, surface: str) -> str:
    """`surface` moved by the amount the card color moved from `base` to `pick`, per channel."""
    return "#" + "".join(f"{max(0, min(255, s + p - b)):02x}" for s, p, b in zip(rgb(surface), rgb(pick), rgb(base)))


def css_rgb(h: str) -> str:
    return "rgb(%d, %d, %d)" % tuple(rgb(h))


# --- the files ---------------------------------------------------------------------------------------------------------------

@pytest.fixture
def client(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(settings))


def test_the_pinned_copy_matches_its_sha_file_and_starts_with_its_version_line():
    data = TOOL.read_bytes()
    assert SHA.read_text(encoding="utf-8") == f"{hashlib.sha256(data).hexdigest()}  colortool.js\n", \
        "colortool.js and colortool.js.sha256 differ: pin a copy with web/tools/pin-colortool, never edit the file"
    assert re.fullmatch(r"/\* colortool v\d+ \*/", data.decode("utf-8").split("\n", 1)[0])


def load_pin_script():
    loader = importlib.machinery.SourceFileLoader("pin_colortool", str(PIN))
    spec = importlib.util.spec_from_loader("pin_colortool", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def test_pin_colortool_copies_the_file_verbatim_writes_the_sha_and_refuses_a_file_without_the_version_line(tmp_path):
    pin = load_pin_script()
    static = tmp_path / "static"
    static.mkdir()
    pin.STATIC = static
    src = tmp_path / "stackshot-shared"
    src.mkdir()
    # a v7 file with bytes a text rewrite would change: CRLF, a tab, a trailing space and no final newline
    body = b"/* colortool v7 */\n/* x */\t \r\nwindow.ColorTool = {};"
    (src / "colortool.js").write_bytes(body)
    assert pin.main([str(src / "colortool.js")]) == 0
    assert (static / "colortool.js").read_bytes() == body
    assert (static / "colortool.js.sha256").read_text() == f"{hashlib.sha256(body).hexdigest()}  colortool.js\n"
    assert sorted(p.name for p in static.iterdir()) == ["colortool.js", "colortool.js.sha256"]       # no temporary file left
    # a file with another first line, and a path that is not there: refused, and the pinned copy stays as it was
    (src / "other.js").write_bytes(b"// not the tool\n")
    assert pin.main([str(src / "other.js")]) == 1
    assert pin.main([str(src / "missing.js")]) == 1
    assert (static / "colortool.js").read_bytes() == body
    assert sorted(p.name for p in static.iterdir()) == ["colortool.js", "colortool.js.sha256"]
    # the real pinned copy re-pins to itself (the default source is stackshot's checkout; here the path is given)
    real = tmp_path / "real"
    real.mkdir()
    shutil.copy(TOOL, real / "colortool.js")
    pin.STATIC = tmp_path / "again"
    pin.STATIC.mkdir()
    assert pin.main([str(real / "colortool.js")]) == 0
    assert (pin.STATIC / "colortool.js.sha256").read_text() == SHA.read_text()


def test_the_scripts_are_served_at_both_addresses(client):
    for name, path in (("colortool.js", TOOL), ("colortool-sala.js", WIRING)):
        a, b = client.get("/static/" + name), client.get("/v2/static/" + name)
        assert a.status_code == b.status_code == 200 and a.content == b.content == path.read_bytes(), name
        assert "javascript" in a.headers["content-type"], name


def test_each_page_loads_the_tool_then_the_wiring_once_and_only_the_main_pages_start_the_button(client):
    for name, page in (("index.html", True), ("terminal.html", False)):
        html = (STATIC / name).read_text(encoding="utf-8")
        head, body = html.split("</head>", 1)
        assert head.count(SRC % "colortool.js") == 1 and head.count(SRC % "colortool-sala.js") == 1, name
        assert head.index(SRC % "colortool.js") < head.index(SRC % "colortool-sala.js"), name
        assert "colortool" not in re.sub(r"<!--.*?-->", "", body, flags=re.S).replace(INIT, ""), name
        assert body.count(INIT) == (1 if page else 0), name
    # in index.html the scripts come after the stylesheets (the wiring reads their colors) and the theme-color metas (it keeps their content)
    head = (STATIC / "index.html").read_text(encoding="utf-8").split("</head>", 1)[0]
    assert head.rindex('rel="stylesheet" href="static/') < head.index(SRC % "colortool.js")
    assert head.rindex('name="theme-color"') < head.index(SRC % "colortool.js")
    # the start call is the last script of the body, after the app's own
    body = (STATIC / "index.html").read_text(encoding="utf-8").split("</head>", 1)[1]
    assert body.rstrip().endswith(INIT + "\n</body>\n</html>") and body.index("static/app.js") < body.index(INIT)
    served = {"main": client.get("/").text, "v2": client.get("/v2/").text, "terminal": client.get("/terminal?arg=x").text}
    for what, page in served.items():
        assert len(re.findall(r'<script src="static/colortool\.js\?v=\d+"></script>', page)) == 1, what
        assert len(re.findall(r'<script src="static/colortool-sala\.js\?v=\d+"></script>', page)) == 1, what
        assert page.count(INIT) == (0 if what == "terminal" else 1), what
    # the mount: the last thing in the side panel, under "Show all sessions" and the note, and nothing else in the page
    side = served["main"].split('<aside id="sidebar">', 1)[1].split("</aside>", 1)[0]
    assert re.findall(r'id="([\w-]+)"', side)[-3:] == ["show-back", "side-note", "side-colors"]
    assert served["main"].count('id="side-colors"') == 1 and served["v2"].count('id="side-colors"') == 1
    assert 'id="side-colors"' not in served["terminal"]


def test_the_temporary_try_out_is_gone():
    assert not (STATIC / "colortry.js").exists() and not (STATIC.parent.parent.parent / "tests" / "test_colortry.py").exists()
    # the storage key keeps its old name (a look stored by the try-out must keep loading); no other trace of the old file or its wording
    root = STATIC.parent.parent.parent
    for f in [*STATIC.glob("*.js"), *STATIC.glob("*.html"), *STATIC.glob("*.css"), root / "src" / "sala_web" / "colors.py", root / "src" / "sala_web" / "app.py"]:
        if f == TOOL:
            continue
        text = f.read_text(encoding="utf-8")
        assert "colortry.js" not in text and not re.search(r"temporar\w+ (?:colou?r|try-out)|colou?r try-out", text, re.I), f.name
        if f != WIRING:
            assert "sala-colortry" not in text, f.name


def wiring_block(start: str, end: str) -> str:
    return WIRING.read_text(encoding="utf-8").split(start, 1)[1].split(end, 1)[0]


def test_the_wiring_hands_the_tool_the_settings_sala_agreed():
    src = WIRING.read_text(encoding="utf-8")
    cfg = src.split("var cfg = {", 1)[1].split("\n  };", 1)[0]
    assert 'storageKey: "sala-colortry"' in cfg and 'gate: "warn"' in cfg and 'mount: "#side-colors"' in cfg and 'api: "api/colors/combos"' in cfg
    for key in ("isDark: isDark", "shipped: shipped", "onApply: onApply", "css: CSS", "preview: PREVIEW"):
        assert key in cfg, key
    block = cfg.split("vars: {", 1)[1].split("}", 1)[0]
    got = {k: re.findall(r'"(--[\w-]+)"', body) for k, body in re.findall(r"(\w+): \[([^\]]*)\]", block)}
    assert got == VARS
    assert re.search(r"var SHIFTED = \[%s\]" % re.escape(", ".join(f'"{v}"' for v in SHIFTED)), src)
    # the wiring itself talks to nobody: the saved list is the tool's one call, to the address above
    for banned in ("fetch(", "XMLHttpRequest", "sendBeacon", "WebSocket", "EventSource", "document.cookie", "localStorage", "Authorization", "Bearer", "sender"):
        assert banned not in src.split("*/", 1)[1], banned
    tool = TOOL.read_text(encoding="utf-8")
    assert len(re.findall(r"\bfetch\(", tool)) == 1 and "XMLHttpRequest" not in tool and "sendBeacon" not in tool
    # the aliases the panel reads: --card --line --fg --mut --ibd --ifill, each pointing at sala's own token
    alias = wiring_block('":root{', '}",')
    assert dict(re.findall(r"--(\w+):var\(--(\w+)\)", alias)) == {"card": "panel", "line": "border", "fg": "text", "mut": "muted", "ibd": "faint", "ifill": "bg"}
    for name in ("card", "line", "fg", "mut", "ibd", "ifill"):
        for css in STATIC.glob("*.css"):
            assert not re.search(r"--%s\s*:" % name, css.read_text(encoding="utf-8")), (css.name, name, "sala's own token now shares a name with the panel's alias")


def test_the_wiring_leaves_the_light_theme_alone_and_gives_the_tool_only_the_texts_it_reads():
    # the tool runs onApply in the light theme too, with nothing resolved or stored ({}): the hook must return there after putting the
    # status-bar meta back, before it reads r.card (rgb(undefined) throws, and a changed look in light would be a wrong answer)
    src = WIRING.read_text(encoding="utf-8")
    hook = src.split("function onApply(r, s, set, addClass, engine) {", 1)[1].split("\n  }\n", 1)[0]
    first = hook.strip().split("\n", 1)[0]
    assert re.fullmatch(r"if \(!r \|\| !r\.card \|\| !isDark\(\)\) \{ setMeta\(null\); return; \}", first), first
    assert "engine.ship()" in hook and hook.index("engine.ship()") > hook.index("return;")
    # the tool's own light-theme contract is in its header (a re-pin that drops it must be looked at here)
    tool = TOOL.read_text(encoding="utf-8")
    assert "the light theme too (resolved and stored are then {}" in tool
    # cfg.text: only the keys the pinned tool reads, as plain strings
    cfg = src.split("var cfg = {", 1)[1].split("\n  };", 1)[0]
    text = cfg.split("text: {", 1)[1].split("},", 1)[0]
    keys = re.findall(r"^\s*(\w+):", text, flags=re.M)
    assert keys and set(keys) <= {"signIn", "note", "example"}, keys
    assert re.search(r'example: "#[0-9a-f]{6}"', text)
    for k in keys:
        assert re.search(r"\bX\.%s\b" % k, tool), (k, "the pinned tool does not read this text")


def declarations(css: str) -> set[str]:
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    return {re.sub(r"\s+", "", d) for d in css.split(";") if d.strip()}


def test_the_preview_rules_repeat_the_declarations_of_the_rules_they_stand_for():
    # the badge and the effort tag are drawn by rules scoped to the title bar and the overview; the preview strip has neither, so the wiring
    # repeats those declarations under .ct-prev. They must stay equal to the originals.
    mirrored = dict(re.findall(r'"(\.ct-prev[^{"]*)\{([^}]*)\}"', WIRING.read_text(encoding="utf-8")))
    css = (STATIC / "style.css").read_text(encoding="utf-8")
    sessions = (STATIC / "sessions.css").read_text(encoding="utf-8")
    originals = {".ct-prev .pill": css.split("#top .pill {", 1)[1],
                 ".ct-prev .pill.role-front": css.split("#top .pill.role-front {", 1)[1],
                 ".ct-prev .sp-tag": sessions.split("#overview-pane .sp-tag {", 1)[1],
                 ".ct-prev .sp-eff.eff-max": sessions.split("#overview-pane .sp-eff.eff-max {", 1)[1]}
    assert set(mirrored) - {".ct-prev"} == set(originals)
    for sel, body in mirrored.items():
        if sel == ".ct-prev":      # the effort tag's two custom properties, as the overview defines them in the dark theme
            want = declarations(body)
            assert any(want <= declarations(m) for m in re.findall(r"(--eff-max-bg:[^}]*)\}", sessions)), sel
            continue
        assert declarations(body) <= declarations(originals[sel].split("}", 1)[0]), sel


# the two blocks of style.css that declare the dark theme's shipped small-label and disabled tokens (the only place a stylesheet declares them)
SHIPPED_BLOCK = re.compile(r'(?::root:not\(\[data-theme="light"\]\)|:root\[data-theme="dark"\]) \{ --label-bg:[^}]*\}')


def test_the_dark_theme_ships_the_small_label_and_disabled_tokens_in_two_blocks_the_light_theme_has_none():
    css = (STATIC / "style.css").read_text(encoding="utf-8")
    blocks = SHIPPED_BLOCK.findall(css)
    assert len(blocks) == 2, blocks
    want = {**{SHIPPED_TOKENS[k]: v for k, v in SHIPPED_LABELS.items()}, "--dis-op": "1"}
    for b in blocks:
        assert dict(re.findall(r"(--[\w-]+):\s*([^;}]+?)\s*(?:;|\})", b)) == want, b
    # the first sits in the dark media query, the second under data-theme="dark": neither in the light block
    assert css.index(blocks[0]) > css.index("@media (prefers-color-scheme: dark) {") and css.index(blocks[0]) < css.index(blocks[1])
    for tok in want:
        assert tok not in THEMES["light"] and tok not in THEMES["dark"], tok       # not in the token blocks test_theme_contrast.py compares


def test_the_stylesheets_read_the_variables_with_a_fallback_so_nothing_changes_without_the_tool():
    seen = {n: 0 for n in ("--accent-solid", "--accent-on-solid", "--label-bg", "--label-fg", "--label-bd", "--dis-bg", "--dis-fg", "--dis-op")}
    css_files = sorted(STATIC.glob("*.css")) + [STATIC.parent / "v2" / "extra.css"]
    for f in css_files:
        text = f.read_text(encoding="utf-8")
        for name in seen:
            for m in re.finditer(r"var\(%s(.)" % re.escape(name), text):
                seen[name] += 1
                assert m.group(1) == ",", (f.name, name, "is read without a fallback")
            if f.name == "style.css":        # the dark theme's shipped look is declared in the two blocks checked below, nowhere else
                text = SHIPPED_BLOCK.sub("", text)
            assert not re.search(r"(?<![\w(])%s\s*:" % re.escape(name), text), (f.name, name, "is declared by a stylesheet: only the tool sets it")
    assert all(seen.values()), seen
    css = (STATIC / "style.css").read_text(encoding="utf-8")
    assert (".send-btn:disabled { opacity: var(--dis-op, .45); background: var(--dis-bg, var(--accent-solid, var(--accent)));"
            " color: var(--dis-fg, var(--accent-on-solid, var(--accent-text))); cursor: default; }") in css
    # the mount shows only while the tool has drawn its button there (nothing in the light theme)
    assert ".side-colors { display: none; }" in css and ".side-colors:has(.ct:not([hidden])) {" in css


# --- the browser -------------------------------------------------------------------------------------------------------------

@pytest.fixture
def fake(tmp_path, monkeypatch):
    """A fake stackshot, and sala's token / address files pointed at it (set before `served` builds its settings: list this fixture first)."""
    f = FakeStackshot(tmp_path / "stackshot-cfg")
    monkeypatch.setenv("SALA_WEB_STACKSHOT_TOKEN", str(f.token_file))
    monkeypatch.setenv("SALA_WEB_STACKSHOT_URL", str(f.url_file))
    yield f
    f.close()


def combo(name: str, values: dict, cid: str) -> dict:
    return {"id": cid, "name": name, "values": values, "saved": 1792800000, "via": "sala-web"}


def full(look: dict) -> dict:
    """A stored look as the 14 values of a saved combination: the neutrals under it."""
    base = {"bg": "#161617", "card": "#1f1f21", "line": "#2c2c2e", "fg": "#ececea", "mut": "#a3a29d", "ibd": "#929190"}
    return {**base, **look}


def wait(browser, expr: str, what: str, ms: int = 15000):
    v = browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      let v; try { v = (%s); } catch (e) { v = null; }
      if (v || Date.now() - t0 > %d) res(v ? true : null); else setTimeout(poll, 100); })(); })""" % (expr, ms))
    assert v, what


def go(browser, url: str, *, dark: bool = True, width: int = 390, height: int = 844, ready: str = "true", script: str | None = None,
       blocked: list[str] | None = None, button: bool = True):
    """Open `url` at width x height in the dark or the light scheme, with an optional script run before the page's own; wait for the button."""
    browser.send("Page.enable")
    browser.send("Network.enable")
    if blocked:
        browser.send("Network.setBlockedURLs", {"urls": blocked})
    if script:
        browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": script})
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": width <= 760})
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark" if dark else "light"}]})
    browser.send("Page.navigate", {"url": url})
    if button:
        wait(browser, "document.querySelector('#side-colors .ct-btn') !== null", f"{url}: the color button was not drawn")
    wait(browser, ready, f"{url}: the page was not drawn")


def inline(browser) -> dict:
    return browser.evaluate("(() => { const s = document.documentElement.style, out = {};"
                            "for (const n of %s) out[n] = s.getPropertyValue(n); return out; })()" % json.dumps(OWN_VARS))


def stored(browser):
    return browser.evaluate("localStorage.getItem('sala-colortry')")


def meta(browser) -> str:
    return browser.evaluate("document.querySelector('meta[name=theme-color][media*=dark]').content")


def click(browser, selector: str) -> None:
    assert browser.evaluate("(() => { const b = document.querySelector(%s); if (!b) return false; b.click(); return true; })()" % json.dumps(selector)), selector


def open_side(browser, width: int) -> None:
    """The side panel open: the drawer on a phone, pinned on a wide screen."""
    browser.evaluate("document.body.classList.add('%s'); ''" % ("side-open" if width < 761 else "side-pin"))
    time.sleep(0.4)       # the slide is over


def open_panel(browser) -> None:
    click(browser, "#ct-btn")
    wait(browser, "!document.querySelector('#ct-pop').hidden", "the panel did not open")


def type_hex(browser, key: str, value: str) -> None:
    browser.evaluate("(() => { const i = document.getElementById('ct-h-%s'); i.value = '%s'; i.dispatchEvent(new Event('input', { bubbles: true })); })()" % (key, value))


def preset(browser, pid: str) -> None:
    click(browser, f".ct-preset[data-p={json.dumps(pid)}]")


def reload(browser) -> None:
    browser.evaluate("window.__before_reload = true; setTimeout(() => location.reload(), 0); ''")
    end = time.time() + 15
    while time.time() < end:
        try:
            if browser.evaluate("!window.__before_reload && document.readyState === 'complete' && document.querySelector('#side-colors .ct-btn') !== null"):
                return
        except RuntimeError:        # the target is navigating: asked again
            pass
        time.sleep(0.1)
    pytest.fail("the page did not reload")


GEOMETRY = """(() => {
  const r = (e) => { const b = e.getBoundingClientRect(); return { l: b.left, t: b.top, r: b.right, b: b.bottom, w: b.width, h: b.height }; };
  const btn = document.querySelector('.ct-btn'), side = document.getElementById('sidebar'), toggle = document.querySelector('#sidebar .toggle');
  const pop = document.getElementById('ct-pop');
  const fixed = [...document.querySelectorAll('body *')].filter((e) => getComputedStyle(e).position === 'fixed' && getComputedStyle(e).display !== 'none'
    && (e.className + e.id).toLowerCase().includes('ct'))
    .map((e) => e.id || e.className);
  const last = (() => { const kids = [...side.children].filter((e) => getComputedStyle(e).display !== 'none'); return kids[kids.length - 1].id; })();
  return { btn: r(btn), side: r(side), toggle: r(toggle), colors: r(document.getElementById('side-colors')), inSidebar: side.contains(btn),
           buttons: document.querySelectorAll('.ct-btn').length, fixed, last, vw: innerWidth, vh: innerHeight,
           btnPosition: getComputedStyle(btn).position, pop: pop.hidden ? null : r(pop), popParent: pop.parentElement.tagName,
           popFixed: getComputedStyle(pop).position === 'fixed', popSideways: pop.scrollWidth > pop.clientWidth, popScrolls: pop.scrollHeight > pop.clientHeight,
           overflowY: getComputedStyle(pop).overflowY, docSideways: document.documentElement.scrollWidth > innerWidth };
})()"""


@pytest.mark.parametrize("width,height", [(360, 740), (1280, 800)])
@pytest.mark.parametrize("path", ["/", "/v2/"])
def test_the_button_sits_last_in_the_side_panel_and_the_panel_opens_upward_fits_and_scrolls(fake, served, browser, width, height, path):
    fake.combos = [combo("An evening look with a rather long name", full(RADIX), "c1"), combo("Warm", full(RADIX), "c2")]
    go(browser, served["url"] + path + CHAT, width=width, height=height, ready=READY_CHAT)
    open_side(browser, width)
    g = browser.evaluate(GEOMETRY)
    assert g["buttons"] == 1 and g["inSidebar"] and g["btnPosition"] not in ("fixed", "absolute"), g          # one button, in the panel, in the flow
    assert g["fixed"] == [], f"a fixed element of the tool is on the page before the panel is opened: {g['fixed']}"      # no floating corner button
    assert g["last"] == "side-colors", g
    assert g["btn"]["t"] >= g["toggle"]["b"] - 0.5, ("the button is not under 'Show all sessions'", g)
    assert g["colors"]["b"] >= g["side"]["b"] - 1 and g["btn"]["b"] <= g["side"]["b"], ("not at the very bottom of the panel", g)     # pinned at the bottom
    assert g["btn"]["l"] >= g["side"]["l"] and g["btn"]["r"] <= g["side"]["r"], g
    # the open panel: in the body, fixed, above the button, inside the window, never sideways; the fields are folded away at first
    open_panel(browser)
    wait(browser, "document.querySelectorAll('#ct-list li').length === 2", "the saved list did not show")
    g = browser.evaluate(GEOMETRY)
    assert g["popParent"] == "BODY" and g["popFixed"] and g["fixed"] == ["ct-pop"], g
    p = g["pop"]
    assert p["b"] <= g["btn"]["t"] + 0.5, ("the panel is not above the button", g)
    assert 0 <= p["l"] and p["r"] <= g["vw"] and 0 <= p["t"] and p["b"] <= g["vh"], ("the panel does not fit the window", p, g["vw"], g["vh"])
    assert not g["popSideways"] and not g["docSideways"], g
    assert browser.evaluate("document.getElementById('ct-fields').hidden") is True, "the fields are not folded away on the first open"
    assert browser.evaluate("(() => { const b = document.getElementById('ct-save'); return b.scrollWidth <= b.clientWidth && b.getClientRects().length === 1 "
                            "&& b.textContent === 'Save' && b.getBoundingClientRect().height < 48; })()") is True, "Save is not one line"
    # opening the fold grows the panel upward from the button, keeps it inside the window, and the panel scrolls there
    closed = p
    click(browser, "#ct-fold")
    wait(browser, "!document.getElementById('ct-fields').hidden", "the fold did not open")
    g = browser.evaluate(GEOMETRY)
    p = g["pop"]
    assert p["b"] <= g["btn"]["t"] + 0.5 and abs(p["b"] - closed["b"]) < 1, ("the panel does not hang from the button", p, closed)
    assert p["t"] < closed["t"] and p["h"] > closed["h"], ("the panel did not grow upward", p, closed)
    assert 0 <= p["l"] and p["r"] <= g["vw"] and 0 <= p["t"] and p["b"] <= g["vh"], ("the open fold does not fit the window", p, g["vw"], g["vh"])
    assert not g["popSideways"] and not g["docSideways"], g
    assert g["overflowY"] in ("auto", "scroll") and g["popScrolls"], ("the panel cannot be scrolled", g)
    # the foot (Reset, the presets, the saved list) stays in view as the fold opens, and the first field can be scrolled to and used inside the window
    in_view = ("(() => { const r = document.getElementById(%s).getBoundingClientRect(), p = document.getElementById('ct-pop').getBoundingClientRect();"
               "return r.top >= p.top - 0.5 && r.bottom <= p.bottom + 0.5 && r.bottom <= innerHeight; })()")
    assert browser.evaluate(in_view % json.dumps("ct-reset")) is True
    browser.evaluate("document.getElementById('ct-h-bg').scrollIntoView(); ''")
    time.sleep(0.2)
    assert browser.evaluate(in_view % json.dumps("ct-h-bg")) is True
    browser.evaluate("document.getElementById('ct-reset').scrollIntoView(); ''")
    time.sleep(0.2)
    assert browser.evaluate(in_view % json.dumps("ct-reset")) is True
    # Escape closes it, and the page behind scrolls nowhere sideways
    browser.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); ''")
    wait(browser, "document.querySelector('#ct-pop').hidden", "Escape did not close the panel")


FOLD_STATE = ("(() => ({ hidden: document.getElementById('ct-fields').hidden, expanded: document.getElementById('ct-fold').getAttribute('aria-expanded'),"
              " shown: document.getElementById('ct-fields').getClientRects().length > 0, text: document.getElementById('ct-fold').textContent,"
              " stored: localStorage.getItem('sala-colortry:fields') }))()")


def test_the_fields_fold_is_closed_on_first_load_and_a_choice_to_open_it_is_kept_in_this_browser(served, browser):
    go(browser, served["url"] + "/")
    open_panel(browser)
    st = browser.evaluate(FOLD_STATE)
    assert st == {"hidden": True, "expanded": "false", "shown": False, "text": "Fields", "stored": None}, st      # closed at first, nothing kept yet
    click(browser, "#ct-fold")
    st = browser.evaluate(FOLD_STATE)
    assert st["hidden"] is False and st["expanded"] == "true" and st["shown"] is True and st["stored"] == "1", st
    assert browser.evaluate("document.querySelectorAll('#ct-fields .ct-row').length") == 14                  # the 14 fields are the fold's content
    reload(browser)
    open_panel(browser)
    st = browser.evaluate(FOLD_STATE)
    assert st["hidden"] is False and st["expanded"] == "true" and st["shown"] is True, ("the open fold was not restored", st)
    click(browser, "#ct-fold")                                                                                # closing it is kept too
    st = browser.evaluate(FOLD_STATE)
    assert st["hidden"] is True and st["expanded"] == "false" and st["stored"] is None, st
    reload(browser)
    open_panel(browser)
    assert browser.evaluate(FOLD_STATE)["hidden"] is True


def test_a_stored_open_state_of_the_fold_is_restored_and_the_fold_state_is_not_a_look(served, browser):
    go(browser, served["url"] + "/", script="localStorage.setItem('sala-colortry:fields', '1');")
    open_panel(browser)
    st = browser.evaluate(FOLD_STATE)
    assert st["hidden"] is False and st["expanded"] == "true" and st["shown"] is True, st
    assert stored(browser) is None                                  # the fold's key is not the look's: no look is stored by it
    assert all(v == "" for v in inline(browser).values())


def mix_hex(a: str, b: str, pct: int) -> str:
    """`a` at pct percent over `b`, per channel, rounded: the tool's and the wiring's mix."""
    return "#" + "".join(f"{round(x * pct / 100 + y * (100 - pct) / 100):02x}" for x, y in zip(rgb(a), rgb(b)))


LABEL_ROWS = ["labbg", "labfg", "labbd", "disbg", "disfg"]
ROWS_STATE = ("(() => Object.fromEntries(%s.map((k) => [k, { hex: document.getElementById('ct-h-' + k).value,"
              " pick: document.getElementById('ct-p-' + k).value, state: document.getElementById('ct-s-' + k).textContent }])))()" % json.dumps(LABEL_ROWS))


def test_with_nothing_set_the_label_and_disabled_fields_show_sala_s_shipped_values_and_follow_the_others_once_one_they_follow_is_set(served, browser):
    go(browser, served["url"] + "/")
    open_panel(browser)
    click(browser, "#ct-fold")
    wait(browser, "document.getElementById('ct-fields').getClientRects().length > 0", "the fields did not unfold")
    assert stored(browser) is None
    # nothing set: the five fields that follow others show what sala ships, not a value worked out from the live ones
    ship = browser.evaluate("SalaColors.cfg.shipped()")
    solid, card = DARK["--accent"], DARK["--panel"]
    want = SHIPPED_LABELS
    assert solid == want["labfg"] == "#f0a06a"                  # the single-orange rule: the label text is the one orange too
    assert {k: ship[k] for k in LABEL_ROWS} == want, ship
    rows = browser.evaluate(ROWS_STATE)
    assert rows == {k: {"hex": want[k], "pick": want[k], "state": "shipped"} for k in LABEL_ROWS}, rows
    assert all(v == "" for v in inline(browser).values())
    # the card is set: the label background follows it (card, background and link are what it follows), the other four still ship
    type_hex(browser, "card", "#202022")
    rows = browser.evaluate(ROWS_STATE)
    assert rows["labbg"]["state"] == "follows the others" and rows["labbg"]["hex"] == mix_hex(solid, "#202022", 16), rows["labbg"]
    assert {k: rows[k] for k in LABEL_ROWS if k != "labbg"} == {k: {"hex": want[k], "pick": want[k], "state": "shipped"} for k in LABEL_ROWS if k != "labbg"}
    # the solid fill is set too: the disabled pair follows it (the label colors follow the link color, which is still the shipped one)
    type_hex(browser, "solid", "#c96442")
    rows = browser.evaluate(ROWS_STATE)
    assert rows["disbg"]["state"] == rows["disfg"]["state"] == "follows the others", rows
    assert rows["labfg"]["state"] == rows["labbd"]["state"] == "shipped" and rows["labfg"]["hex"] == want["labfg"], rows
    # a link color set: the three label fields now follow it
    type_hex(browser, "link", "#ffa057")
    rows = browser.evaluate(ROWS_STATE)
    assert all(rows[k]["state"] == "follows the others" for k in LABEL_ROWS), rows
    assert rows["labfg"]["hex"] == rows["labbd"]["hex"] == "#ffa057", rows
    # Reset puts every row back to the shipped value
    click(browser, "#ct-reset")
    rows = browser.evaluate(ROWS_STATE)
    assert rows == {k: {"hex": want[k], "pick": want[k], "state": "shipped"} for k in LABEL_ROWS}, rows


# the 14 values of the shipped dark look: what the dark theme ships, every key
SHIPPED_DARK = {"bg": "#161617", "card": "#1f1f21", "fg": "#ececea", "mut": "#a3a29d", "line": "#2c2c2e", "ibd": "#929190", "link": "#f0a06a",
                "solid": "#f0a06a", "onsolid": "#1f1f21", "labbg": "#3a2619", "labfg": "#f0a06a", "labbd": "#3a2619", "disbg": "#2a2a2c", "disfg": "#a3a29d"}


@pytest.mark.parametrize("name,path", PAGES)
def test_the_shipped_dark_look_is_the_saved_combination_on_every_page_with_nothing_set(served, browser, name, path):
    """Live now / the shipped value of all 14 keys, read by the panel's cfg: the combination exactly, on the main page, /v2 and the terminal page
    (which has no palette of its own and answers from the wiring's fallback table). The pinned preset Old orange is untouched (its own values)."""
    go(browser, served["url"] + path, button=name != "terminal", ready="document.readyState === 'complete'")
    ship = browser.evaluate("SalaColors.cfg.shipped()")
    assert {k: ship[k] for k in SHIPPED_DARK} == SHIPPED_DARK, ship
    assert all(v == "" for v in inline(browser).values()) and stored(browser) is None


def test_the_shipped_look_in_the_light_theme_is_still_worked_out_from_the_solid_fill(served, browser):
    go(browser, served["url"] + "/", dark=False, button=False, ready="document.readyState === 'complete'")
    ship = browser.evaluate("SalaColors.cfg.shipped()")
    light = THEMES["light"]
    assert ship["labbg"] == ship["labbd"] == ship["solid"] == light["--accent"] and ship["labfg"] == ship["onsolid"] == light["--accent-text"], ship
    assert ship["disbg"] == mix_hex(ship["solid"], light["--panel"], 45) and ship["disfg"] == mix_hex(ship["onsolid"], light["--panel"], 45), ship
    # and the page draws the light theme's labels and its faded Send as before
    probe = browser.evaluate("""(() => { const c = document.createElement('span'); c.className = 'ucount'; c.textContent = '3'; document.body.appendChild(c);
      const s = getComputedStyle(c), b = document.querySelector('#composer .send-btn'); b.disabled = true; const d = getComputedStyle(b);
      return { ucount: [s.color, s.backgroundColor, s.boxShadow], send: [d.opacity, d.backgroundColor, d.color] }; })()""")
    assert probe["ucount"][:2] == [css_rgb(light["--accent-text"]), css_rgb(light["--accent"])], probe
    assert probe["send"] == ["0.45", css_rgb(light["--accent"]), css_rgb(light["--accent-text"])], probe


@pytest.mark.parametrize("path", ["/", "/v2/"])
def test_the_dark_page_draws_the_shipped_labels_and_disabled_buttons(served, browser, path):
    """The computed colors, not only the tokens: the unread count, the front badge (title bar) and a search hit's front tag are #f0a06a on #3a2619 with an
    outline of #3a2619; the disabled Send, Create session and Start quick session are #a3a29d on #2a2a2c at full opacity; links, solid buttons stay #f0a06a."""
    go(browser, served["url"] + path, ready="document.readyState === 'complete'")
    got = browser.evaluate("""(() => {
      const mk = (parent, tag, cls) => { const e = document.createElement(tag); e.className = cls; e.textContent = 'x'; parent.appendChild(e); return e; };
      const top = document.getElementById('top') || document.body, sr = mk(document.body, 'div', 'x'); sr.id = 'search-pane';
      const els = { ucount: mk(document.body, 'span', 'ucount'), front: mk(top, 'span', 'pill role-front'), hit: mk(sr, 'span', 'se-role front') };
      const out = {};
      for (const [k, e] of Object.entries(els)) { const s = getComputedStyle(e); out[k] = [s.color, s.backgroundColor, parseFloat(s.borderTopWidth) > 0 ? s.borderTopColor : null, s.boxShadow]; }
      for (const sel of ['#composer .send-btn', '.ns-submit', '#ns-submit', '#sd-submit']) {
        const b = document.querySelector(sel); if (!b) continue; b.disabled = true; const s = getComputedStyle(b); out[sel] = [s.color, s.backgroundColor, s.opacity];
      }
      return out; })()""")
    orange, fill, grey_bg, grey_fg = css_rgb("#f0a06a"), css_rgb("#3a2619"), css_rgb("#2a2a2c"), css_rgb("#a3a29d")
    assert got["ucount"][:2] == [orange, fill] and fill in got["ucount"][3], got["ucount"]
    # (the /v2 badge has no border at all, `border: 0`: nothing to color)
    assert got["front"][:3] == [orange, fill, fill if path == "/" else None], got["front"]
    assert got["hit"][:3] == [orange, fill, fill], got["hit"]
    seen = [k for k in got if k.startswith(("#", "."))]
    assert "#composer .send-btn" in seen, seen
    for k in seen:
        assert got[k] == [grey_fg, grey_bg, "1"], (k, got[k])


@pytest.mark.parametrize("name,path", PAGES[:2])
def test_a_preset_a_field_and_the_card_set_inline_properties_on_html_and_the_look_is_stored_and_survives_a_reload(served, browser, name, path):
    go(browser, served["url"] + path)
    assert all(v == "" for v in inline(browser).values()) and stored(browser) is None
    open_panel(browser)
    preset(browser, "radix")
    want = {v: "" for v in OWN_VARS}
    for k, val in RADIX_STORED.items():
        for v in VARS[k]:
            want[v] = val
    want.update({"--dis-bg": "#2a2a2c", "--dis-fg": "#a3a29d", "--dis-op": "1"})           # the disabled pair goes with its opacity
    assert inline(browser) == want
    assert json.loads(stored(browser)) == RADIX_STORED                                     # a flat map of #rrggbb, only the fields that differ from the unset value
    # a field typed in: its variables and no others; the card moves the four surfaces that follow it by the same step
    type_hex(browser, "card", "#202022")
    got = inline(browser)
    assert got["--panel"] == "#202022"
    for v in SHIFTED:
        assert got[v] == shifted(DARK["--panel"], "#202022", DARK[v]), v
    # the page background moves the status-bar color; the light meta is not touched
    type_hex(browser, "bg", "#1a1a1b")
    assert meta(browser) == "#1a1a1b" and browser.evaluate("document.querySelector('meta[name=theme-color][media*=light]').content") == THEMES["light"]["--bg"]
    assert browser.evaluate("getComputedStyle(document.body).backgroundColor") == "rgb(26, 26, 27)"
    assert json.loads(stored(browser)) == {**RADIX_STORED, "bg": "#1a1a1b", "card": "#202022"}
    before = inline(browser)
    reload(browser)
    assert inline(browser) == before and meta(browser) == "#1a1a1b"                          # applied again, before the panel is opened
    assert browser.evaluate("document.getElementById('ct-pop').hidden") is True


@pytest.mark.parametrize("how", ["Reset", "Live now"])
def test_reset_and_live_now_remove_every_inline_property_and_put_the_status_bar_color_back(served, browser, how):
    go(browser, served["url"] + "/")
    open_panel(browser)
    preset(browser, "two")
    type_hex(browser, "card", "#202022")
    type_hex(browser, "bg", "#1a1a1b")
    type_hex(browser, "disbg", "#334455")
    got = inline(browser)
    assert got["--dis-op"] == "1" and got["--code-bg"] != "" and got["--user-bubble"] != "" and meta(browser) == "#1a1a1b", got
    assert sum(1 for v in got.values() if v) >= 12      # (Two oranges' label fill and text equal the shipped ones now, so they are not stored)
    click(browser, "#ct-reset" if how == "Reset" else ".ct-preset[data-p=live]")
    assert all(v == "" for v in inline(browser).values()), inline(browser)                   # including --dis-op and the four shifted surfaces
    left = browser.evaluate("(() => { const s = document.documentElement.style, out = []; for (let i = 0; i < s.length; i++) out.push(s[i]); return out; })()")
    assert set(left) <= {"--app-h", "--banner-h"}, left                                       # the page's own two layout properties stay; nothing else
    assert stored(browser) is None
    assert meta(browser) == META_DARK
    assert browser.evaluate("getComputedStyle(document.body).backgroundColor") == css_rgb(DARK["--bg"])
    # and the idle Send button is the shipped look again: the flat grey pair at full opacity
    assert browser.evaluate(SEND_DISABLED) == ["1", css_rgb("#2a2a2c"), css_rgb("#a3a29d")]


SEND_DISABLED = "(() => { const b = document.querySelector('#composer .send-btn'); b.disabled = true; const c = getComputedStyle(b); return [c.opacity, c.backgroundColor, c.color]; })()"


def test_the_idle_send_button_is_exactly_the_disabled_pair_with_no_fade_while_a_preset_holds_it(served, browser):
    go(browser, served["url"] + "/" + CHAT, ready=READY_CHAT)
    shipped = ["1", css_rgb(SHIPPED_LABELS["disbg"]), css_rgb(SHIPPED_LABELS["disfg"])]
    assert browser.evaluate(SEND_DISABLED) == shipped                  # as shipped: the pair at full opacity, no fade
    open_panel(browser)
    preset(browser, "two")
    type_hex(browser, "disbg", "#334455")
    assert browser.evaluate(SEND_DISABLED) == ["1", css_rgb("#334455"), css_rgb(inline(browser)["--dis-fg"])]
    click(browser, "#ct-reset")
    assert browser.evaluate(SEND_DISABLED) == shipped


FIRST_PAINT = """
localStorage.setItem('sala-colortry', %s);
new MutationObserver(() => {
  if (document.body && window.__atBody === undefined) {
    window.__atBody = { style: document.documentElement.style.cssText,
                        meta: [...document.querySelectorAll('meta[name=theme-color]')].map((m) => m.content), hasButton: !!document.querySelector('.ct-btn') };
  }
}).observe(document, { childList: true, subtree: true });
"""


def test_a_look_stored_by_the_earlier_try_out_is_applied_in_the_head_before_the_body_is_drawn(served, browser):
    go(browser, served["url"] + "/", script=FIRST_PAINT % json.dumps(json.dumps(OLD_LOOK)))
    at_body = browser.evaluate("window.__atBody")
    style = dict(re.findall(r"(--[\w-]+):\s*([^;]+);", at_body["style"]))
    assert style["--bg"] == "#1f1f21" and style["--side-bg"] == "#1f1f21", at_body        # the page background is there when the body starts
    assert style["--accent"] == "#ffa057" and style["--accent-solid"] == "#c96442" and style["--label-bg"] == "#462100", at_body
    assert style["--dis-bg"] == "#2a2a2c" and style["--dis-op"] == "1", at_body
    assert at_body["meta"][1] == "#1f1f21" and at_body["hasButton"] is False, at_body     # the status-bar color too, and the button comes later
    assert browser.evaluate("getComputedStyle(document.body).backgroundColor") == "rgb(31, 31, 33)"
    assert json.loads(stored(browser)) == OLD_LOOK                                          # read, not rewritten


def test_the_light_theme_is_left_as_shipped_and_the_button_follows_the_theme_in_effect(served, browser):
    errors = "window.__errs = []; addEventListener('error', (e) => window.__errs.push(String(e.message)));"
    go(browser, served["url"] + "/", dark=False, button=False,
       script=errors + "localStorage.setItem('sala-colortry', %s);" % json.dumps(json.dumps(OLD_LOOK)))
    wait(browser, "document.readyState === 'complete'", "the page did not load")
    assert browser.evaluate("window.__errs") == []                                          # the tool runs onApply in light: it must not throw there
    assert meta(browser) == META_DARK                                                       # the dark status-bar meta is as shipped, whatever look is stored
    assert browser.evaluate("document.querySelector('.ct-btn')") is None and browser.evaluate("document.getElementById('ct-pop')") is None      # no button
    assert browser.evaluate("getComputedStyle(document.getElementById('side-colors')).display") == "none"
    assert all(v == "" for v in inline(browser).values())                                   # the stored dark look is not applied to it
    assert browser.evaluate("getComputedStyle(document.body).backgroundColor") == css_rgb(THEMES["light"]["--bg"])
    # a data-theme set on <html> is the theme in effect
    browser.evaluate("document.documentElement.setAttribute('data-theme', 'dark'); ''")
    wait(browser, "document.querySelector('#side-colors .ct-btn') && !document.getElementById('ct').hidden", "the button did not appear for data-theme=dark")
    assert inline(browser)["--bg"] == "#1f1f21" and inline(browser)["--accent"] == "#ffa057" and inline(browser)["--dis-op"] == "1"
    assert meta(browser) == "#1f1f21"
    browser.evaluate("document.documentElement.setAttribute('data-theme', 'light'); ''")
    wait(browser, "document.getElementById('ct').hidden", "the button did not go for data-theme=light")
    assert all(v == "" for v in inline(browser).values()) and meta(browser) == META_DARK
    assert browser.evaluate("getComputedStyle(document.getElementById('side-colors')).display") == "none"
    assert browser.evaluate("window.__errs") == []


def test_the_terminal_page_applies_the_stored_look_and_has_no_button(served, browser):
    go(browser, served["url"] + "/terminal?arg=x", script="localStorage.setItem('sala-colortry', %s);" % json.dumps(json.dumps(OLD_LOOK)), button=False)
    wait(browser, "document.readyState === 'complete' && document.getElementById('term-full')", "the terminal page did not load")
    got = inline(browser)
    assert got["--bg"] == "#1f1f21" and got["--accent"] == "#ffa057" and got["--dis-op"] == "1", got
    assert browser.evaluate("document.querySelector('.ct-btn')") is None and browser.evaluate("document.querySelector('.ct-pop')") is None
    assert browser.evaluate("getComputedStyle(document.body).backgroundColor") == "rgb(0, 0, 0)"      # the Terminal stays black


def test_without_the_shared_file_the_page_loads_as_shipped(served, browser):
    go(browser, served["url"] + "/" + CHAT, ready=READY_CHAT, blocked=["*static/colortool.js*"], button=False)
    assert browser.evaluate("typeof window.ColorTool") == "undefined" and browser.evaluate("window.SalaColors") is None
    assert browser.evaluate("document.querySelector('.ct-btn')") is None
    # the dark theme's shipped look is the stylesheet's own (style.css), so it holds without the script
    assert browser.evaluate(SEND_DISABLED) == ["1", css_rgb(SHIPPED_LABELS["disbg"]), css_rgb(SHIPPED_LABELS["disfg"])]


def saved(browser) -> list[str]:
    return browser.evaluate("[...document.querySelectorAll('#ct-list .ct-use')].map((b) => b.textContent)")


def test_the_saved_list_lists_applies_saves_replaces_and_deletes(fake, served, browser):
    fake.combos = [combo("Evening", full(RADIX), "c1"), combo("Warm", full({**RADIX, "solid": "#bd561d"}), "c2")]
    go(browser, served["url"] + "/")
    open_panel(browser)
    wait(browser, "document.querySelectorAll('#ct-list .ct-use').length === 2", "the saved list did not show")
    assert saved(browser) == ["Evening", "Warm"]
    assert [r["method"] + r["path"] for r in fake.requests if "colors" in r["path"]] == ["GET/client/colors/combos"]
    # apply: the look is kept like a pick
    click(browser, "#ct-list li:nth-child(2) .ct-use")
    want = {k: v for k, v in RADIX_STORED.items() if k != "onsolid"}      # the white text on the new fill is what an unset one gives
    assert json.loads(stored(browser)) == {**want, "solid": "#bd561d"} and inline(browser)["--accent-solid"] == "#bd561d"
    # save under a name (no window.prompt), with the 14 values as they are now
    browser.evaluate("window.prompt = () => { throw new Error('window.prompt is not used'); }; ''")
    type_hex(browser, "link", "#ee9455")
    browser.evaluate("document.getElementById('ct-name').value = '  Mine  '; document.getElementById('ct-save').click(); ''")
    wait(browser, "document.querySelectorAll('#ct-list .ct-use').length === 3", "the save was not answered")
    assert saved(browser) == ["Evening", "Warm", "Mine"]
    post = [r["body"] for r in fake.requests if r["method"] == "POST"][-1]
    assert post["name"] == "Mine" and post["sender"] == "sala-web" and set(post["values"]) == set(KEYS) and post["values"]["link"] == "#ee9455"
    # the same name in another case replaces it, in place
    browser.evaluate("document.getElementById('ct-name').value = 'mine'; document.getElementById('ct-save').click(); ''")
    wait(browser, "document.getElementById('ct-n-saved').textContent.startsWith('Replaced')", "the replace was not answered")
    assert saved(browser) == ["Evening", "Warm", "mine"] and len(fake.combos) == 3
    # delete: the first press asks, the second deletes
    click(browser, "#ct-list li:nth-child(1) .ct-del")
    assert [c["name"] for c in fake.combos] == ["Evening", "Warm", "mine"]
    click(browser, "#ct-list li:nth-child(1) .ct-del")
    wait(browser, "document.querySelectorAll('#ct-list .ct-use').length === 2", "the delete was not answered")
    assert [c["name"] for c in fake.combos] == ["Warm", "mine"]
    assert [r["body"] for r in fake.requests if r["path"].endswith("/delete")] == [{"id": "c1", "sender": "sala-web"}]
    # a combination another page saved shows when the panel is opened again
    # (sala's route leaves out a row that is not a whole combination of 14 colors)
    fake.combos.append(combo("From stackshot", full(RADIX), "c9"))
    fake.combos.append(combo("Not whole", full({}), "c10"))
    click(browser, "#ct-btn")
    click(browser, "#ct-btn")
    wait(browser, "document.querySelectorAll('#ct-list .ct-use').length === 3", "the list was not read again on opening")


def test_a_pick_goes_nowhere_but_this_browser_and_a_save_carries_no_token_or_sender(fake, served, browser):
    go(browser, served["url"] + "/")
    open_panel(browser)
    wait(browser, "document.getElementById('ct-save')", "no saved list box")
    browser.events.clear()
    preset(browser, "radix")
    type_hex(browser, "link", "#ee9455")
    browser.evaluate("document.getElementById('ct-name').value = 'Mine'; document.getElementById('ct-save').click(); ''")
    wait(browser, "document.getElementById('ct-n-saved').textContent.startsWith('Saved')", "the save was not answered")
    sent = [e["params"].get("request", {}) for e in browser.events if e.get("method") == "Network.requestWillBeSent"]
    mine = [r for r in sent if "api/colors/combos" in r.get("url", "")]
    assert [r["method"] for r in mine] == ["POST"]
    for r in sent:
        blob = json.dumps(r)
        assert not re.search(r"authorization|bearer|sala-web|" + re.escape(fake.token), blob, re.I), blob
        if r in mine:
            assert set(json.loads(r["postData"])) == {"name", "values"}
        else:
            assert not re.search(r"ee9455|f76b15|sala-colortry", blob, re.I), blob


@pytest.fixture(params=["standby", "down", "no-setup"])
def unavailable(request, tmp_path, monkeypatch):
    """Stackshot answers 503, is not listening, or this machine has no token or address (list this fixture before `served`)."""
    f = None
    if request.param != "no-setup":
        f = FakeStackshot(tmp_path / "stackshot-cfg")
        monkeypatch.setenv("SALA_WEB_STACKSHOT_TOKEN", str(f.token_file))
        monkeypatch.setenv("SALA_WEB_STACKSHOT_URL", str(f.url_file))
        if request.param == "standby":
            f.combos_reply = (503, {"error": "The saved list is on a standby copy.", "field": None})
        else:
            f.close()               # nothing listens at the address any more
    yield request.param
    if f and request.param == "standby":
        f.close()


def test_the_panel_works_with_the_saved_list_unavailable(unavailable, served, browser):
    go(browser, served["url"] + "/")
    open_panel(browser)
    wait(browser, "document.getElementById('ct-n-saved').textContent !== ''", "no note about the saved list")
    note = browser.evaluate("document.getElementById('ct-n-saved').textContent")
    assert len(note) > 10 and not re.search(r"fake-|Bearer|127\.0\.0\.1", note), note      # a sentence, with no token and no address in it
    assert browser.evaluate("document.querySelectorAll('#ct-list .ct-use').length") == 0
    # everything else works: a preset, a field, Reset
    preset(browser, "radix")
    assert inline(browser)["--accent-solid"] == "#f76b15"
    type_hex(browser, "fg", "#dddddd")
    assert inline(browser)["--text"] == "#dddddd"
    click(browser, "#ct-reset")
    assert all(v == "" for v in inline(browser).values())
    # and a Save says so in the panel
    browser.evaluate("document.getElementById('ct-name').value = 'x'; document.getElementById('ct-save').click(); ''")
    wait(browser, "document.getElementById('ct-n-saved').textContent.length > 10", "the failed save was not reported")
    assert saved(browser) == []
