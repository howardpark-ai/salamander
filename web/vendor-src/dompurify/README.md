# dompurify: the source of `static/vendor/purify.min.js`

DOMPurify turns the HTML that `marked` writes for a reply into the nodes the page shows (`web/README.md`, *Develop*). Only
`static/vendor/purify.min.js` is used by the app; this directory is the recipe that reproduces it and is not wired into CI or
the deploy. The file is the release's own `dist/purify.min.js`, copied byte for byte: the repo builds nothing, and nothing is
loaded from a CDN at runtime. A reply keeps the library's defaults but for what `static/shared.js` takes out (`MD_PURIFY`,
`mdAttr`, `mdStyle`), so an update's changes to those defaults reach replies: read them in the release notes.

## Pinned version

| package | version | published |
|---|---|---|
| `dompurify` | 3.5.0 | Nov 22nd 2026 |

It was the project's current release on Thu Nov 26th 2026 and was taken then, four days old: the composer's two-week rule
(`../cm6-composer/README.md`) was not kept, because the project ends the 3.4 line with this release. Its only dependency,
`@types/trusted-types` (optional, types alone), is pinned in `package-lock.json` and is not part of the file.

The file committed with this recipe: 30,839 bytes, sha256
`f69a46022ab1f53e969c8ebbca98172c8995785a9b3be72ea4a12d25b1a1bf67`. It is the same file as `dist/purify.min.js` at the tag
`3.5.0` of `github.com/cure53/DOMPurify`.

## Update

In a scratch directory outside the repo:

```sh
cp package.json package-lock.json /path/to/scratch/ && cd /path/to/scratch
npm ci --ignore-scripts --no-audit --no-fund   # exactly the lockfile's version, checked against its sha512
cp node_modules/dompurify/dist/purify.min.js <repo>/web/src/sala_web/static/vendor/purify.min.js
```

To move the version, read its release notes, change it in `package.json`, `npm install --save-exact --ignore-scripts`, commit
the lockfile with the new file, and update `LICENSE` and `LICENSE-MPL`, the table, size and sha256 above, the version in
`web/README.md` and `VERSION` and `SHA256` in `web/tests/test_md_rules.py`. Then run that file and `test_md_rules_ui.py`.

## License

DOMPurify is copyright (C) Cure53 and other contributors, released under the Apache License 2.0 or the Mozilla Public License
2.0: `LICENSE` and `LICENSE-MPL` here are the release's own, and the file's banner names the version and the license.
