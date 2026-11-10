"""The interface text table, ready to put in front of a script that a test runs in node.

static/shared.js and the page scripts word their text through `tl()` (static/i18n.js). A test that cuts a function out of one of
them and runs it in node puts `prelude()` first: the English table, the Korean table, the lookup, and just enough of `document` for
the lookup to start in the language given. Nothing else of the page is faked here.
"""

from __future__ import annotations

from pathlib import Path

STATIC = Path(__file__).resolve().parents[1] / "src" / "sala_web" / "static"


def prelude(lang: str = "en") -> str:
    """JavaScript that defines SalaI18n and tl in `lang` ("en" or "ko")."""
    stub = (
        "globalThis.window = globalThis;\n"
        "globalThis.document = { documentElement: { getAttribute: () => %r, setAttribute() {} }, readyState: 'complete',\n"
        "  querySelectorAll: () => [], addEventListener() {} };\n" % lang
    )
    return stub + "".join((STATIC / name).read_text() + "\n" for name in ("i18n-en.js", "i18n-ko.js", "i18n.js"))
