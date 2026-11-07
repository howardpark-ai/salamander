"""sala UI v2, served at /v2 next to the unchanged current UI.

v2 is a LAYER over the live v1 sources, not a second copy of them. `design.py` rewrites a v1 stylesheet, the page and app.js to
the v2 look (the type scale, two weights, the 4 px grid, two radii, stackshot's icons); `extra.css` holds what a rule-by-rule
pass cannot make (two button levels, tinted tags, the theme's orange, one row per agent on a phone); `layer.py` serves the
result at request time, cached by the source file's mtime, and sends every other /v2/ path to the handler it would have without
the prefix. So v1 work that lands while v2 is being tried shows in /v2 by itself, and at the switch-over the layer's output is
committed as the source (README, "/v2").

`fonts/` holds D2Coding (the code face, SIL Open Font License 1.1: `OFL.txt` travels with it).
"""
