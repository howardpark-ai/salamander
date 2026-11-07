# cm6-composer: the source of `static/vendor/cm6-composer.min.js`

CodeMirror 6 bundled as one classic script for sala's composer (`web/README.md`, *The composer*). Only the
bundled output is used by the app; this directory is the recipe that reproduces it and is not wired into CI or the deploy.
The repo has no npm build, so the bundle is built in a scratch directory and the output committed, the way `marked.min.js`
and `purify.min.js` are vendored. Nothing is loaded from a CDN at runtime.

## What is in it

`entry.js` imports from `@codemirror/state`, `view` and `commands` and exports one global, `cm6Composer`:
`createEditor(parent, opts)` (the editor configured as the composer: line wrapping, the list markers drawn by replace
decorations (a bullet is a disc the theme draws, half the text's size) and made atomic for the caret, a caret that rests at
the item's text and never before the marker (a transaction filter; ArrowLeft there goes on to the line above), and a
selection whose ends never take a bullet (Shift+Home, Shift+Left, Shift+Up/Down and a drag stop at the item's text or before the
bullet; Select All is the one range that keeps the first marker), Backspace at an
item's start leaving the list, Enter/Shift+Enter continuing a list
and an empty item ending it, Tab and Shift+Tab as indent, Ctrl+arrows, every key behind an IME guard, the theme on the app's CSS
variables, a placeholder in a compartment: the bundle's own `div` over the empty line, outside the contenteditable), `resetDoc(view, text)` (the text replaced, the undo history started over, no change
event), `setPlaceholder(view, text)`, plus `EditorView`, `EditorState`, `EditorSelection`, `LIST_RE` and `versions`. It also
sets `EditorView.EDIT_CONTEXT = false`, so that on Android the keyboard stays with the contenteditable (the keyboard's image
insertion; `web/README.md`). The comments in `entry.js` say how each rule is implemented. The document is always the plain
text that is sent: the dot and the indent of a list item are drawn, never typed.

There is no markdown parser in it: the list rule is the composer's own regular expression (`LIST_RE`), as it was before
CodeMirror. (`@codemirror/commands` brings `@codemirror/language` and the lezer packages along; the bundle is 268 KB minified,
88 KB gzipped.)

## Pinned versions

Direct dependencies, exact (the newest release of each that was at least two weeks old on Thu Oct 15th 2026):

| package | version | published |
|---|---|---|
| `@codemirror/state` | 6.7.6 | Sep 22nd 2026 |
| `@codemirror/view` | 6.43.13 | Sep 22nd 2026 (6.43.14 of Oct 7th left out) |
| `@codemirror/commands` | 6.11.1 | Sep 15th 2026 |
| `esbuild` (dev) | 0.28.2 | Aug 8th 2026 |

Transitive packages were resolved with `npm install --before=2026-10-01T00:00:00Z` (nothing newer than Oct 1st 2026) and are
pinned in `package-lock.json`: `@codemirror/language` 6.12.4; `@lezer/common` 1.5.3, `highlight` 1.2.5, `lr` 1.4.10;
`@marijn/find-cluster-break` 1.0.4, `crelt` 1.0.7, `style-mod` 4.1.4, `w3c-keyname` 2.2.8.

## Rebuild

In a scratch directory outside the repo (node 24, npm 11 were used):

```sh
cp entry.js package.json package-lock.json banner.txt /path/to/scratch/ && cd /path/to/scratch
npm ci --no-audit --no-fund        # exactly the lockfile's versions
npm run build                      # esbuild: iife, global cm6Composer, es2020, minified, the banner on top
cp dist/cm6-composer.min.js <repo>/web/src/sala_web/static/vendor/cm6-composer.min.js
```

`npm run build` is `esbuild entry.js --bundle --minify --format=iife --global-name=cm6Composer --target=es2020
--charset=utf8 --legal-comments=none --banner:js="$(cat banner.txt)" --outfile=dist/cm6-composer.min.js`. To move a version,
change it in `package.json`, `npm install --save-exact` (with `--before=<date>` to keep the two-week rule for what it pulls
in), commit the lockfile with the new bundle, and update `banner.txt`, the `versions` export in `entry.js`, the table above
and `VERSIONS` in `web/tests/test_composer_cm6.py`. A change to `entry.js` is a rebuild and a commit of the bundle with it.

The bundle committed with this recipe: 268,115 bytes, 87,676 gzipped (`gzip -9`), sha256
`7a8366c8eb356c4453d43c32f6e7252289524f2389ea0c1fac3a0555c70c6691`. It was rebuilt from the committed lockfile in a fresh directory
with the commands above and came out byte for byte the same.

## License

CodeMirror and lezer are MIT, copyright (C) 2018-2021 by Marijn Haverbeke and others: `LICENSE` here is their text (copied from
`@codemirror/view`), and the bundle's banner names the packages and points to this directory. `crelt`, `style-mod`,
`w3c-keyname` and `@marijn/find-cluster-break` are MIT by the same author.
