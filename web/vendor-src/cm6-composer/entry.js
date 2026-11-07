// cm6-composer: CodeMirror 6 configured as sala's composer. Bundled into
// web/src/sala_web/static/vendor/cm6-composer.min.js by the recipe in this directory (README.md); the page gets one global,
// `cm6Composer`, with `createEditor(parent, opts)` and the few CodeMirror pieces app.js needs around it. The document is
// always the plain text that is sent: what this file adds is how it looks and what the keys do, never a character of the
// text ("- item" is sent as "- item", "1. item" as "1. item"; the dot and the indent are drawn, not typed).
//
// What the lists do:
//   1. a list line looks like a list: "- " / "* " become a dot (a disc half the text's size, drawn by the theme) at a slight indent, "1. " keeps its number;
//   2. Backspace at an item's start visibly leaves the list: the marker and the indent go, the text stays, plain;
//   3. the caret never lands inside the marker ("- ", "1. "): the range is atomic for arrows, taps and programmatic moves;
//      and (a caret in front of the bullet felt awkward)
//      it never rests before it either: a caret at a list line's start is put at the end of the marker, the item's text;
//   4. Tab indents (a list item nests), Shift+Tab outdents.
//
// The rules below are the composer's own from before CodeMirror (app.js had them as tabKey, listBreak and ctrlArrow, with
// the tests in web/tests/test_composer_lists.py), so the move changes how a list is drawn, not what the keys do.

import { Compartment, EditorSelection, EditorState, Prec, RangeSetBuilder, StateField } from "@codemirror/state";
import { Decoration, EditorView, ViewPlugin, WidgetType, keymap } from "@codemirror/view";
import { history, historyKeymap, insertNewline, standardKeymap } from "@codemirror/commands";

// On Android CodeMirror (6.43) hands the keyboard to the browser's EditContext API instead of the contenteditable. The
// composer stays on the contenteditable: it is what Chrome on Android offers a keyboard's image insertion to
// (InputConnection.commitContent), and the whole paste chain of app.js was tuned
// on it. Set before the first view is made.
EditorView.EDIT_CONTEXT = false;

// A list line: optional leading spaces, then "- ", "* " or digits and ". " (the marker), then the item's text.
export const LIST_RE = /^( *)(?:([-*]) |(\d+)\. )/;
const INDENT = "  ";

// The marker as drawn: the indent and the marker text are replaced by this widget (note 1). The level is the nesting
// depth (two spaces of indent each), set as a CSS custom property so the theme places the glyph and the hanging indent.
class MarkerWidget extends WidgetType {
  constructor(label, level, ordered) { super(); this.label = label; this.level = level; this.ordered = ordered; }
  eq(other) { return other.label === this.label && other.level === this.level && other.ordered === this.ordered; }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-li-mark " + (this.ordered ? "cm-li-num" : "cm-li-bullet");
    span.textContent = this.label;  // a bullet's "•" is invisible: the theme draws the disc
    span.style.setProperty("--li-level", String(this.level));
    return span;
  }
  ignoreEvent() { return false; }  // a tap on the marker is the editor's: the caret lands at the marker's edge
}

function listDecorations(doc) {
  const marks = new RangeSetBuilder(), lines = new RangeSetBuilder();
  for (let i = 1; i <= doc.lines; i++) {
    const line = doc.line(i);
    const m = LIST_RE.exec(line.text);
    if (!m) continue;
    const level = Math.floor(m[1].length / INDENT.length);
    const ordered = m[3] !== undefined;
    lines.add(line.from, line.from, Decoration.line({ class: "cm-li", attributes: { style: `--li-level:${level}` } }));
    marks.add(line.from, line.from + m[0].length,
              Decoration.replace({ widget: new MarkerWidget(ordered ? m[3] + "." : "•", level, ordered) }));
  }
  return { marks: marks.finish(), lines: lines.finish() };
}

// The markers of the whole document, recomputed on every change (a composer is short). The replace set is also the
// atomic ranges (note 3): cursor motion skips them, and a deletion into one takes the whole marker.
const listField = StateField.define({
  create: (state) => listDecorations(state.doc),
  update: (value, tr) => (tr.docChanged ? listDecorations(tr.state.doc) : value),
  provide: (f) => [
    EditorView.decorations.from(f, (v) => v.marks),
    EditorView.decorations.from(f, (v) => v.lines),
    EditorView.atomicRanges.of((view) => view.state.field(f).marks),
  ],
});

// The marker's length on a line of the given text (indent included), or null when the line is not a list line.
function markerSpan(lineText) {
  const m = LIST_RE.exec(lineText);
  return m ? m[0].length : null;
}

// A selection end that would land inside a marker (a tap on the glyph, a programmatic move, an edit that makes a
// marker around the caret) is moved to the marker's edge: forward motion goes to the text, anything else to the line's
// start. Arrow keys never get here (the atomic ranges skip the marker in cursor motion); this is the net under them.
// And a caret (an empty selection) never rests before the marker either: at the line's start, or anywhere in
// the marker, it is put at the marker's end, the item's text.
// A range never selects a marker with its ends (Shift+Home used to select the bullet): its start, at the line's start or in the marker, is put at the item's text (Shift+Home,
// Shift+Left, Shift+Up, a drag that begins on the bullet); its end, strictly inside the marker, is put at the line's start
// (Shift+Down onto a list line, a drag that ends on the bullet), so the range stops before the bullet and leaves it out. A
// range from the document's start to its end, anchor first (Select All), keeps its ends and takes the first marker with it.
// A transaction that changes the text keeps the older rule (an end in the marker goes to its edge; an end at a line's start
// stays: Tab on a selection).
const keepOutOfMarkers = EditorState.transactionFilter.of((tr) => {
  if (!tr.selection && !tr.docChanged) return tr;
  const doc = tr.newDoc, main = tr.newSelection.main, prev = tr.startState.selection.main;
  const edge = (pos, from) => {
    const line = doc.lineAt(pos), len = markerSpan(line.text);
    if (len === null) return pos;
    const to = line.from + len;
    if (pos <= line.from || pos >= to) return pos;
    return from < pos || tr.docChanged ? to : line.from;
  };
  const textStart = (pos) => {
    const line = doc.lineAt(pos), len = markerSpan(line.text);
    return len === null ? pos : Math.max(pos, line.from + len);
  };
  const lineStart = (pos) => {  // the line's start when pos is strictly inside the marker, else pos
    const line = doc.lineAt(pos), len = markerSpan(line.text);
    return len !== null && pos > line.from && pos < line.from + len ? line.from : pos;
  };
  let head, anchor;
  if (main.empty) {
    head = anchor = textStart(main.head);
  } else if (tr.docChanged) {
    head = edge(main.head, tr.changes.mapPos(prev.head));
    anchor = edge(main.anchor, tr.changes.mapPos(prev.anchor));
  } else if (main.anchor === 0 && main.head === doc.length) {  // Select All
    return tr;
  } else {
    let lo = textStart(main.from), hi = lineStart(main.to);
    if (lo > hi) lo = hi = textStart(main.from);  // a range inside the marker is a caret at the item's text
    [anchor, head] = main.anchor <= main.head ? [lo, hi] : [hi, lo];
  }
  if (head === main.head && anchor === main.anchor) return tr;
  // sequential: the positions are in the document after tr's changes (without it they would be mapped through them)
  return [tr, { selection: EditorSelection.single(anchor, head), sequential: true }];
});

// ArrowLeft with the caret at an item's text start: the marker is not a place to stop, so the key goes on to the end of the
// line above, as it would from the start of any line (the atomic skip and the filter above would otherwise leave it where it is).
const leftOverMarker = (view) => {
  const r = view.state.selection.main, doc = view.state.doc, line = doc.lineAt(r.head), len = markerSpan(line.text);
  if (!r.empty || len === null || r.head !== line.from + len || line.number === 1) return false;
  view.dispatch({ selection: { anchor: line.from - 1 }, scrollIntoView: true, userEvent: "select" });
  return true;
};

// Shift+ArrowLeft with the head at an item's text start, the selection empty or reaching back from there: the same, the head
// goes on to the end of the line above (the anchor stays), instead of onto the marker, which a selection may not hold
// A selection reaching forward to that head is shortened by the editor's own key (to the line's start).
const shiftLeftOverMarker = (view) => {
  const r = view.state.selection.main, doc = view.state.doc, line = doc.lineAt(r.head), len = markerSpan(line.text);
  if (len === null || r.head !== line.from + len || r.anchor < r.head) return false;
  if (line.number > 1) view.dispatch({ selection: EditorSelection.single(r.anchor, line.from - 1), scrollIntoView: true, userEvent: "select" });
  return true;
};

// Never during an IME composition: a key an IME is processing arrives with keyCode 229 or isComposing (Chrome on Android
// wraps every composition in such a key), and the view is composing between compositionstart and compositionend. The IME
// takes Enter, Tab and Backspace then; the commands below leave the key to the browser, which commits the composed text
// (and breaks the line) itself, once. The observer runs ahead of the keymap and cancels nothing.
let imeKey = false;
const noteKey = EditorView.domEventObservers({ keydown(e) { imeKey = e.isComposing || e.keyCode === 229; } });
const plain = (cmd) => (view) => (imeKey || view.compositionStarted ? false : cmd(view));
// a keymap with every command of it behind the same guard (CodeMirror's own Enter, Backspace and Delete would otherwise act on
// a key the IME is processing)
const guarded = (map) => map.map((b) => Object.assign({}, b, b.run ? { run: plain(b.run) } : {}, b.shift ? { shift: plain(b.shift) } : {}));

// Enter on an empty item (the marker and nothing else): the list ends, the marker and its indent go, the line stays,
// empty. A selection across lines is not this rule's.
const endEmptyItem = (view) => {
  const r = view.state.selection.main, line = view.state.doc.lineAt(r.from);
  if (r.to > line.to) return false;
  const len = markerSpan(line.text);
  if (len === null || line.text.slice(len).trim()) return false;
  view.dispatch({ changes: { from: line.from, to: line.to, insert: "" }, selection: { anchor: line.from }, userEvent: "delete" });
  return true;
};

// A new line on a list item: the next item follows, the same indent and marker ("- ", "* "; a number counts up), the text
// after the caret moved behind it, a selection within the line replaced. A selection across lines, or the caret before the
// marker's end, is a plain break.
const continueItem = (view) => {
  const r = view.state.selection.main, line = view.state.doc.lineAt(r.from);
  if (r.to > line.to) return false;
  const m = LIST_RE.exec(line.text);
  if (!m || r.from < line.from + m[0].length) return false;
  const insert = "\n" + m[1] + (m[3] === undefined ? m[2] + " " : String(Number(m[3]) + 1) + ". ");
  view.dispatch({ changes: { from: r.from, to: r.to, insert }, selection: { anchor: r.from + insert.length },
                  userEvent: "input", scrollIntoView: true });
  return true;
};

// The new line: an empty item ends its list; a list item continues; anything else is a plain line break, no auto-indent.
const newline = (view) => endEmptyItem(view) || continueItem(view) || insertNewline(view);

// Backspace at the start of an item's text (right after the marker): the marker and the indent go, the text stays, plain
// (note 2). Anywhere else Backspace is the editor's own.
const leaveList = (view) => {
  const r = view.state.selection.main;
  if (!r.empty) return false;
  const line = view.state.doc.lineAt(r.head), len = markerSpan(line.text);
  if (len === null || r.head !== line.from + len) return false;
  view.dispatch({ changes: { from: line.from, to: r.head, insert: "" }, selection: { anchor: line.from }, userEvent: "delete" });
  return true;
};

// Tab: two spaces at the caret, in place of the selection. On a list line, or with a selection across lines, it is an
// indent of the line(s) instead: two spaces at the start of every line the selection touches (a selection that ends at a
// line's start leaves that line out), the caret and the selection staying on the same text. Shift+Tab takes up to two
// leading spaces off each of those lines; with none to take, nothing happens (the key is still taken: no focus move).
const tabKey = (outdent) => (view) => {
  const { state } = view, doc = state.doc, r = state.selection.main;
  const first = doc.lineAt(r.from);
  const last = doc.lineAt(r.to > r.from && doc.sliceString(r.to - 1, r.to) === "\n" ? r.to - 1 : r.to);
  if (!outdent && first.number === last.number && !LIST_RE.test(first.text)) {
    view.dispatch({ changes: { from: r.from, to: r.to, insert: INDENT }, selection: { anchor: r.from + INDENT.length },
                    userEvent: "input", scrollIntoView: true });
    return true;
  }
  const edits = [];
  for (let n = first.number; n <= last.number; n++) {
    const line = doc.line(n);
    if (!outdent) edits.push({ from: line.from, insert: INDENT });
    else { const k = /^ {0,2}/.exec(line.text)[0].length; if (k) edits.push({ from: line.from, to: line.from + k }); }
  }
  if (!edits.length) return true;
  const changes = state.changes(edits);
  // An offset moves by what changed above it and, on its own line, before it (assoc 1: it stays behind an indent inserted
  // at it). On a list line the indent is drawn with the marker, so an offset at the line's start stays before it (assoc -1):
  // it would otherwise land inside the marker.
  const at = (pos) => (pos === doc.lineAt(pos).from && LIST_RE.test(doc.lineAt(pos).text) ? -1 : 1);
  view.dispatch({ changes, selection: EditorSelection.single(changes.mapPos(r.anchor, at(r.anchor)), changes.mapPos(r.head, at(r.head))),
                  userEvent: outdent ? "delete.dedent" : "input.indent", scrollIntoView: true });
  return true;
};

// Ctrl+Left/Right cross a line break instead of stopping at it; Ctrl+Up/Down jump a line, as in Windows editors. Shift
// extends the selection. Anything else is the editor's own (Ctrl+Left/Right by words).
const ctrlArrow = (name, extend) => (view) => {
  const doc = view.state.doc, r = view.state.selection.main, focus = r.head, line = doc.lineAt(focus);
  const start = line.from + (markerSpan(line.text) || 0);  // a list line starts, for the caret, after its marker
  let to = null;
  if (name === "ArrowLeft" && focus <= start && line.from > 0) to = line.from - 1;
  else if (name === "ArrowRight" && focus === line.to && focus < doc.length) to = focus + 1;
  else if (name === "ArrowUp") to = focus > start ? line.from : doc.line(Math.max(1, line.number - 1)).from;
  else if (name === "ArrowDown") to = line.number < doc.lines ? doc.line(line.number + 1).from : doc.length;
  if (to === null) return false;
  view.dispatch({ selection: EditorSelection.single(extend ? r.anchor : to, to), scrollIntoView: true, userEvent: "select" });
  return true;
};

// The theme: the app's CSS variables (style.css), so light and dark follow the app. The editor sits inside the composer
// row (which has the border and the background), takes the row's width and grows with its lines up to 40vh, then scrolls,
// as the textarea did: 22px a line and 4px above and below, so one line is the send button's 30px. A list line hangs its
// wrapped lines under the text (padding-left and a negative text-indent of the same size: the glyph's room plus the
// level's indent), and the glyph sits a little in from the left (note 1).
const LEVEL = "calc(1.5em + var(--li-level, 0) * 1.25em)";
const theme = EditorView.theme({
  "&": { flex: "1", minWidth: "0", color: "var(--text)", backgroundColor: "transparent", font: "inherit" },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": { font: "inherit", lineHeight: "22px", overflowY: "auto", overflowX: "hidden", maxHeight: "40vh" },
  ".cm-content": { padding: "4px 0", caretColor: "var(--text)" },
  ".cm-line": { padding: "0" },
  ".cm-line.cm-li": { paddingLeft: LEVEL, textIndent: `calc(0px - ${LEVEL})` },
  ".cm-li-mark": { display: "inline-block", textIndent: "0", boxSizing: "border-box", minWidth: "1.5em",
                   marginLeft: "calc(var(--li-level, 0) * 1.25em)", color: "var(--muted)", whiteSpace: "nowrap" },
  // the bullet is a disc drawn in CSS, not a font's "•" (that came out tiny, and differently in every font): half the
  // text's size across, the colour of the marker, its middle on the middle of the lowercase letters (vertical-align: middle).
  // The same em as the line's, so the hanging indent and the marker's width agree. The "•" stays in the DOM as the widget's one
  // text node (CodeMirror's composition handling breaks on a widget with a child element), unpainted, in a box of fixed width.
  ".cm-li-bullet": { paddingLeft: "0.3em", width: "1.5em", WebkitTextFillColor: "transparent" },
  ".cm-li-bullet::before": { content: '""', display: "inline-block", width: "0.5em", height: "0.5em", borderRadius: "50%",
                             backgroundColor: "var(--muted)", verticalAlign: "middle" },
  ".cm-li-num": { paddingLeft: "0.1em", paddingRight: "0.35em", fontVariantNumeric: "tabular-nums" },
  // the placeholder sits over the empty line, outside the contenteditable (placeholderPlugin below): the editor's box is its
  // containing block (CodeMirror makes .cm-editor position: relative), 4px down as the content is, a line high; nothing it
  // does moves the text or the caret, and a text longer than the row ends in an ellipsis instead of wrapping
  ".cm-placeholder": { position: "absolute", left: "0", right: "0", top: "4px", height: "22px", lineHeight: "22px", overflow: "hidden",
                       whiteSpace: "nowrap", textOverflow: "ellipsis", pointerEvents: "none", color: "var(--muted)" },
});

// The placeholder is not CodeMirror's own placeholder() extension (on Chrome on Android the cursor
// sometimes sat behind the explanatory text). That one is a non-editable <span> inside the empty line, which
// gives the line three places for the caret (before the span, after it, before the <br>); a tap past the text's middle puts the
// browser's own caret after the span, CodeMirror leaves it there (all three are document offset 0), and the caret, and Android's
// teardrop handle, is drawn at the end of the placeholder's text. Here the placeholder is a <div class="cm-placeholder"> of its
// own in the editor's box (view.dom), beside the scroller and not in the contenteditable: the empty line is a lone <br>, with one
// place for the caret, the line's start. It is in the DOM only while the document is empty and no composition is under way (it
// goes at compositionstart, as soon as there is text, and comes back at compositionend and when the text is emptied). The
// view's own compositionStarted is read, not a flag of the plugin's: the handlers only trigger sync(), so a missed compositionend or
// a reconfigure in mid-composition cannot leave the placeholder stuck (the view's observers run before a plugin's handlers). The
// accessible name stays in aria-placeholder on the editable, as CodeMirror's own put it.
const placeholderPlugin = (text) => ViewPlugin.fromClass(class {
  constructor(view) {
    this.view = view;
    this.dom = document.createElement("div");
    this.dom.className = "cm-placeholder";
    this.dom.setAttribute("aria-hidden", "true");
    this.dom.textContent = text;
    this.sync();
  }
  sync() {
    const show = this.view.state.doc.length === 0 && !this.view.compositionStarted;
    if (show && !this.dom.isConnected) this.view.dom.appendChild(this.dom);
    else if (!show && this.dom.isConnected) this.dom.remove();
  }
  update() { this.sync(); }
  destroy() { this.dom.remove(); }
}, {
  eventHandlers: {
    compositionstart() { this.sync(); },
    compositionend() { this.sync(); },
  },
});

const placeholderSlot = new Compartment();
const placeholderExt = (text) => [text ? placeholderPlugin(text) : [], EditorView.contentAttributes.of({ "aria-placeholder": text || "" })];
const extensionsOf = new WeakMap();  // view -> the extensions it was made with, for resetDoc

// Create the editor in `parent`. opts:
//   doc          the initial text ("")
//   placeholder  the placeholder text (none; setPlaceholder changes it)
//   label        the aria-label of the editable ("Message")
//   id           the id of the editable element (none)
//   touch()      whether the device is in touch mode now: then Enter is a new line and only Ctrl/Cmd+Enter (and the page's
//                Send button) sends; on a desktop Enter sends and Shift+Enter is a new line (read at each key, so a dock
//                is followed)
//   onSend(view) the send; the text is `view.state.doc.toString()`
//   onChange(text, update) every change of the document made by the user or by dispatch (resetDoc is not one)
//   extensions   more CodeMirror extensions (app.js adds its paste and drop handlers through EditorView.domEventHandlers)
// Returns the EditorView; the text is `view.state.doc.toString()`.
export function createEditor(parent, opts = {}) {
  const touch = typeof opts.touch === "function" ? opts.touch : () => false;
  const send = plain((view) => { if (opts.onSend) opts.onSend(view); return true; });
  const keys = [
    { key: "Enter", run: plain((view) => (touch() ? newline(view) : send(view))) },
    { key: "Shift-Enter", run: plain(newline) },
    { key: "Ctrl-Enter", run: send },
    { key: "Meta-Enter", run: send },
    { key: "Backspace", run: plain(leaveList) },
    { key: "ArrowLeft", run: plain(leftOverMarker) },
    { key: "Shift-ArrowLeft", run: plain(shiftLeftOverMarker) },
    { key: "Tab", run: plain(tabKey(false)) },
    { key: "Shift-Tab", run: plain(tabKey(true)) },
    ...["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].flatMap((n) => [
      { key: "Ctrl-" + n, run: plain(ctrlArrow(n, false)) }, { key: "Shift-Ctrl-" + n, run: plain(ctrlArrow(n, true)) }]),
  ];
  // Escape then Tab leaves the box (CodeMirror's tab-focus mode, which Escape arms for two seconds): the next Tab is the
  // browser's, the focus moving on; any other key, or the focus coming back, arms the editor's Tab again
  const rearmTab = EditorView.domEventHandlers({ focus: (e, view) => { view.setTabFocusMode(false); return false; } });
  // the composer is plain text: a formatting command of the browser (Ctrl+B, a menu) is refused. A line break that reaches
  // the editable as an insertion with no Enter key before it (an IME or a script that commits "\n" as text) is the new-line
  // command's, since the browser's own break would be read back as two lines; not on Android and iOS, where CodeMirror
  // turns the keyboard's Enter into the key press itself, and not during a composition (the browser's own commit)
  const mobile = /Android|iPhone|iPad|iPod/.test(navigator.userAgent);
  const noFormat = EditorView.domEventHandlers({
    beforeinput(e, view) {
      if (e.inputType.startsWith("format") || e.inputType === "insertLink" || e.inputType === "insertHorizontalRule") return true;
      if ((e.inputType === "insertLineBreak" || e.inputType === "insertParagraph") && !mobile && !e.isComposing && !view.compositionStarted) {
        newline(view);
        return true;
      }
      return false;
    },
  });
  const attrs = { autocorrect: "on", autocapitalize: "sentences", spellcheck: "true", "aria-label": opts.label || "Message" };
  if (opts.id) attrs.id = opts.id;
  const extensions = [
    history(),
    EditorView.lineWrapping,
    listField,
    keepOutOfMarkers,
    noteKey,
    Prec.high(keymap.of(keys)),
    rearmTab,
    noFormat,
    keymap.of(guarded([...standardKeymap, ...historyKeymap])),
    theme,
    EditorView.contentAttributes.of(attrs),  // the composer is a contenteditable with the browser's defaults (CodeMirror turns these off for code)
    placeholderSlot.of(placeholderExt(opts.placeholder)),
    opts.onChange ? EditorView.updateListener.of((u) => { if (u.docChanged) opts.onChange(u.state.doc.toString(), u); }) : [],
    opts.extensions || [],
  ];
  const view = new EditorView({ state: EditorState.create({ doc: opts.doc || "", extensions }), parent });
  extensionsOf.set(view, extensions);
  return view;
}

// The text replaced as a textarea's value= does: no undo step, no change event, the caret at the end. The undo history
// starts over (it would otherwise bring back a message just sent, or another session's text).
export function resetDoc(view, text) {
  view.setState(EditorState.create({ doc: text, selection: { anchor: text.length }, extensions: extensionsOf.get(view) }));
}

export function setPlaceholder(view, text) {
  view.dispatch({ effects: placeholderSlot.reconfigure(placeholderExt(text)) });
}

export { EditorView, EditorState, EditorSelection };
export const versions = {
  "@codemirror/state": "6.7.6", "@codemirror/view": "6.43.13", "@codemirror/commands": "6.11.1",
};
