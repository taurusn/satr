// The parser worker (PRD PERF-2): runs lexer.js off the page's thread.
"use strict";
importScripts("vendor/marked.js", "extensions.js", "lexer.js");

const sizeOf = (b) => (b.kind === "plain" ? b.text.length : ((b.token && b.token.raw) || "").length);

self.onmessage = (event) => {
  const { id, source, plain } = event.data;
  try {
    // Blocks go in batches of 500 so no single message is huge (SAFE-5); the context comes with the first.
    const result = self.LinenLex.lex(source, plain);
    const all = result.blocks;
    // Batches of at most 500 blocks and 1 MB of source (SAFE-5); the document context comes with the first.
    let i = 0, part = 0;
    do {
      let j = i, bytes = 0;
      while (j < all.length && j - i < 500 && (j === i || bytes + sizeOf(all[j]) <= 1024 * 1024)) { bytes += sizeOf(all[j]); j++; }
      const batch = all.slice(i, j);
      self.postMessage({ id, ok: true, part, done: j >= all.length, result: part === 0 ? { ...result, blocks: batch } : { blocks: batch } });
      i = j;
      part++;
    } while (i < all.length);
  } catch (error) {
    self.postMessage({ id, ok: false, error: String((error && error.message) || error) });
  }
};
