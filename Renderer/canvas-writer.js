/* Linen's canvas writer (PRD-2 CLI-3, section 9.1 rule 4). Writes positions back into a JSON Canvas file the way
   Obsidian 1.13.7 writes it, so a round trip through Obsidian makes a small diff:
   - tab indents; an object or array whose values are all plain values goes on one line (JSON.stringify), any other
     is spread over lines, one key or element per line; keys whose value is undefined are dropped; no final
     newline (a file in this style that had one keeps it);
   - a file already in that style keeps every byte except the numbers that changed (serialising the parsed file
     reproduces it exactly, and only numbers differ);
   - any other file is normalised once to that style, with positions and sizes as whole numbers and unknown fields
     kept, and the result says so.
   A plain script: self.LinenCanvasWriter in the page, module.exports in node. */
(function (root) {
  "use strict";

  const plain = (v) => v === null || typeof v !== "object";

  // Obsidian's serialiser, re-implemented from its behaviour (docs/research/boards.md section 2).
  function lines(v) {
    if (v === undefined) return ["null"];
    if (plain(v) || !v || Object.prototype.toString.call(v) === "[object Date]") return [JSON.stringify(v)];
    if (Array.isArray(v)) {
      if (v.every(plain)) return [JSON.stringify(v)];
      const out = ["["];
      v.forEach((item, i) => {
        const sub = lines(item);
        sub.forEach((l, j) => out.push("\t" + l + (j === sub.length - 1 && i !== v.length - 1 ? "," : "")));
      });
      out.push("]");
      return out;
    }
    let flat = true;
    for (const k in v) if (Object.prototype.hasOwnProperty.call(v, k) && !plain(v[k])) { flat = false; break; }
    if (flat) return [JSON.stringify(v)];
    const keys = Object.keys(v).filter((k) => v[k] !== undefined);
    const out = ["{"];
    keys.forEach((k, i) => {
      const sub = lines(v[k]);
      sub[0] = JSON.stringify(k) + ":" + sub[0];
      sub.forEach((l, j) => out.push("\t" + l + (j === sub.length - 1 && i !== keys.length - 1 ? "," : "")));
    });
    out.push("}");
    return out;
  }
  const serialise = (obj) => lines(obj).join("\n");

  function isObsidianStyle(text) {
    let obj;
    try { obj = JSON.parse(text); } catch (_) { return false; }
    return serialise(obj) === text.replace(/\n$/, "");
  }

  const KEYS = ["x", "y", "width", "height"];

  /** text: the file as read; positions: { id: {x, y, width, height} } (any subset of keys).
      Returns { text, changed (nodes whose numbers changed), normalised, message }. */
  function write(text, positions) {
    const obj = JSON.parse(text);
    const styled = isObsidianStyle(text);
    const trailing = /\n$/.test(text);
    let changed = 0;
    const nodes = Array.isArray(obj.nodes) ? obj.nodes : [];
    for (const n of nodes) {
      if (!n || typeof n !== "object") continue;
      const p = positions && Object.prototype.hasOwnProperty.call(positions, String(n.id)) ? positions[String(n.id)] : null;
      let did = false;
      if (p) for (const k of KEYS) {
        if (typeof p[k] !== "number" || !isFinite(p[k])) continue;
        const v = Math.round(p[k]);
        if (n[k] !== v) { n[k] = v; did = true; }
      }
      if (!styled) for (const k of KEYS) if (typeof n[k] === "number" && isFinite(n[k]) && !Number.isInteger(n[k])) { n[k] = Math.round(n[k]); did = true; }
      if (did) changed++;
    }
    // Obsidian writes no final newline; a styled file that had one keeps it.
    const out = serialise(obj) + (styled && trailing ? "\n" : "");
    return {
      text: out,
      changed,
      normalised: !styled,
      message: styled ? null : "Rewrote the file in Obsidian's style (whole numbers, tab indents, unknown fields kept); later runs change only the numbers that move",
    };
  }

  const api = { write, serialise, isObsidianStyle };
  root.LinenCanvasWriter = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : typeof globalThis !== "undefined" ? globalThis : this);
