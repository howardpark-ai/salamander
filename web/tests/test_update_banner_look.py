"""The "sala was updated. Reload" strip is the card gray with a solid orange Reload button, in both themes.

The strip used to mix the orange accent 14% into the page background, which comes out brown on the dark theme, and its Reload
was an outlined button. The strip now takes the card gray (`--panel`, so it follows each theme and the color tool) with a
hairline `--border` under it, and Reload is the solid accent button (`--accent-solid`, else `--accent`, with its own text color),
so the eye goes to the button and not to a tinted bar.

Held here, in a headless Chromium, with the banner shown, in the dark and in the light theme:
- the strip's computed background equals a probe element painted with `var(--panel)`, is a neutral gray (its channels
  within 4 of each other), and is not the old orange-over-background mix;
- Reload's computed background is the solid accent and its text is the accent's own text color;
- the strip's text on the strip, and Reload's label on Reload, each hold at least 4.5:1;
- the strip stays thin (one line, under 64 px), keeps role="status" and its hairline, and Reload keeps a visible 2 px outline
  when focused from the keyboard.

Runs in a headless Chromium when one is installed, else skipped.
"""

from __future__ import annotations

import re
import time

import pytest

from conftest import NAME
from test_composer_attach import WAIT_READY

MEASURE = """(() => {
  const root = document.documentElement, banner = document.getElementById('update-banner'), btn = document.getElementById('reload-btn');
  banner.hidden = false;
  const cs = (e) => getComputedStyle(e);
  const probe = (css) => { const p = document.createElement('div'); p.style.cssText = css; document.body.appendChild(p);
    const v = cs(p).backgroundColor; p.remove(); return v; };
  btn.focus();
  const r = banner.getBoundingClientRect();
  return { theme: root.getAttribute('data-theme'), role: banner.getAttribute('role'),
    strip: cs(banner).backgroundColor, stripText: cs(banner).color, border: cs(banner).borderBottomWidth + ' ' + cs(banner).borderBottomColor,
    card: probe('background: var(--panel)'), edge: probe('background: var(--border)'),
    oldMix: probe('background: color-mix(in srgb, var(--accent-solid, var(--accent)) 14%, var(--bg))'),
    accent: probe('background: var(--accent-solid, var(--accent))'), onAccent: probe('background: var(--accent-on-solid, var(--accent-text))'),
    btn: cs(btn).backgroundColor, btnText: cs(btn).color, btnBorder: cs(btn).borderTopWidth, btnWeight: cs(btn).fontWeight,
    focusVisible: btn.matches(':focus-visible'), outline: cs(btn).outlineStyle + ' ' + cs(btn).outlineWidth,
    height: r.height, label: btn.textContent };
})()"""


def rgb(css: str) -> tuple[float, float, float]:
    """A computed color as 0..255 channels: `rgb(...)`, `rgba(...)` or `color(srgb r g b)`."""
    m = re.match(r"rgba?\(([\d.]+)[, ]+([\d.]+)[, ]+([\d.]+)", css)
    if m:
        return tuple(float(x) for x in m.groups())  # type: ignore[return-value]
    m = re.match(r"color\(srgb ([\d.]+) ([\d.]+) ([\d.]+)", css)
    assert m, f"an unreadable color: {css}"
    return tuple(float(x) * 255 for x in m.groups())  # type: ignore[return-value]


def luminance(c: tuple[float, float, float]) -> float:
    lin = [(v / 255) / 12.92 if v / 255 <= 0.03928 else (((v / 255) + 0.055) / 1.055) ** 2.4 for v in c]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def contrast(a: str, b: str) -> float:
    la, lb = luminance(rgb(a)), luminance(rgb(b))
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def set_theme(browser, theme: str) -> None:
    browser.evaluate(f"document.documentElement.setAttribute('data-theme', '{theme}'); ''")
    # let the new custom properties reach the style engine before measuring
    browser.evaluate("new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(() => ok(1))))")


@pytest.mark.parametrize("theme", ["dark", "light"])
def test_the_update_strip_is_the_card_gray_and_reload_is_the_solid_accent(served, browser, theme):
    browser.open(f"{served['url']}/#s={NAME}", dark=(theme == "dark"))
    assert browser.evaluate(WAIT_READY)
    set_theme(browser, theme)
    # a key press first, so the focus the measurement gives Reload counts as a keyboard focus (:focus-visible)
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Shift", "code": "ShiftLeft"})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Shift", "code": "ShiftLeft"})
    deadline = time.monotonic() + 5
    while True:
        m = browser.evaluate(MEASURE)
        if m["focusVisible"] or time.monotonic() > deadline:
            break
        time.sleep(0.05)
    assert m["theme"] == theme and m["role"] == "status" and m["label"] == "Reload", m

    # the strip: the card gray, neutral, and not the orange-over-background mix it used to be
    assert m["strip"] == m["card"], m
    r, g, b = rgb(m["strip"])
    assert max(r, g, b) - min(r, g, b) <= 4, m
    assert m["strip"] != m["oldMix"], m
    assert m["border"].startswith("1px") and m["border"].endswith(m["edge"]), m   # the hairline is --border

    # Reload: the solid accent with its own text color, no outline-button border
    assert m["btn"] == m["accent"] and m["btnText"] == m["onAccent"], m
    assert m["btnBorder"] == "0px" and m["btnWeight"] == "600", m
    assert m["btn"] != m["strip"], m

    # readable: the strip's text on the strip, Reload's label on Reload
    assert contrast(m["stripText"], m["strip"]) >= 4.5, m
    assert contrast(m["btnText"], m["btn"]) >= 4.5, m

    # thin and non-blocking, and the keyboard focus ring stays
    assert m["height"] < 64, m
    assert m["focusVisible"] and m["outline"] == "solid 2px", m
