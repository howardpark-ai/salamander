// MarkdownParser.renumberLists from overtype 2.8.0 (src/parser.js, https://github.com/panphora/overtype), taken verbatim except
// that it is a plain function and `this.LIST_PATTERNS.numbered` is the constant below (the same regular expression as the
// package's LIST_PATTERNS.numbered). Third-party code, not sala's.
//
// MIT License
// Copyright (c) 2025 David Miranda
// The full permission notice is in LICENSE-overtype next to this file and in the bundle's banner.

const NUMBERED = /^( *)(\d{1,9})\.[\t ]+(.*)$/;

/**
 * Renumber all numbered lists in text
 * @param {string} text - Text containing numbered lists
 * @returns {string} Text with renumbered lists
 */
export function renumberLists(text) {
  const lines = text.split('\n');
  const numbersByIndent = new Map();
  let inList = false;

  const result = lines.map(line => {
    const match = line.match(NUMBERED);

    if (match) {
      const indent = match[1];
      const indentLevel = indent.length;
      const content = match[3];

      // If we weren't in a list or indent changed, reset lower levels
      if (!inList) {
        numbersByIndent.clear();
      }

      // Get the next number for this indent level
      const currentNumber = (numbersByIndent.get(indentLevel) || 0) + 1;
      numbersByIndent.set(indentLevel, currentNumber);

      // Clear deeper indent levels
      for (const [level] of numbersByIndent) {
        if (level > indentLevel) {
          numbersByIndent.delete(level);
        }
      }

      inList = true;
      return `${indent}${currentNumber}. ${content}`;
    } else {
      // Not a numbered list item
      if (line.trim() === '' || !line.match(/^\s/)) {
        // Empty line or non-indented line breaks the list
        inList = false;
        numbersByIndent.clear();
      }
      return line;
    }
  });

  return result.join('\n');
}
