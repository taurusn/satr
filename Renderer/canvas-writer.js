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

  /** ENG-8 to ENG-14, ENG-21: what a drag, an undo or a reset writes. state: { nodes: { id: {x, y, width, height,
      pinned} }, edges: { id: {via, fromSide, toSide, labelAt, fromAt, toAt} } }; a key left out is untouched, null removes it, pinned
      false removes the pin. Only those keys change (text, ids, kinds, labels and relations never). Ids no longer on the
      board are skipped and listed. Returns { text, changed, missing, normalised }. */
  function arrange(text, state) {
    const obj = JSON.parse(text);
    const styled = isObsidianStyle(text);
    const trailing = /\n$/.test(text);
    const nodes = Array.isArray(obj.nodes) ? obj.nodes : [], edges = Array.isArray(obj.edges) ? obj.edges : [];
    const byId = new Map(), edgeById = new Map();
    for (const n of nodes) if (n && typeof n === "object") byId.set(String(n.id), n);
    for (const e of edges) if (e && typeof e === "object") edgeById.set(String(e.id), e);
    const linenOf = (o) => (o.linen && typeof o.linen === "object" && !Array.isArray(o.linen) ? o.linen : null);
    const setLinen = (o, k, v) => {
      let L = linenOf(o);
      if (v === null || v === undefined || v === false) {
        if (L && k in L) { delete L[k]; if (!Object.keys(L).length) delete o.linen; return true; }
        return false;
      }
      if (!L) { if (o.linen !== undefined) return false; L = o.linen = {}; } // a linen value that is not an object is left alone
      if (JSON.stringify(L[k]) === JSON.stringify(v)) return false;
      L[k] = v;
      return true;
    };
    let changed = 0;
    const missing = [];
    for (const [id, p] of Object.entries((state && state.nodes) || {})) {
      const n = byId.get(id);
      if (!n) { missing.push(id); continue; }
      let did = false;
      for (const k of KEYS) {
        if (typeof p[k] !== "number" || !isFinite(p[k])) continue;
        const v = Math.round(p[k]);
        if (n[k] !== v) { n[k] = v; did = true; }
      }
      if (p.pinned === true || p.pinned === false) did = setLinen(n, "pinned", p.pinned === true ? true : null) || did;
      if (did) changed++;
    }
    for (const [id, p] of Object.entries((state && state.edges) || {})) {
      const e = edgeById.get(id);
      if (!e) { missing.push(id); continue; }
      let did = false;
      if (p.via !== undefined) did = setLinen(e, "via", Array.isArray(p.via) ? p.via.map((q) => [Math.round(q[0]), Math.round(q[1])]) : null) || did;
      const frac = (v) => (typeof v === "number" && isFinite(v) ? Math.round(Math.max(0, Math.min(1, v)) * 1000) / 1000 : null);
      for (const k of ["labelAt", "fromAt", "toAt"]) if (p[k] !== undefined) did = setLinen(e, k, frac(p[k])) || did;
      for (const k of ["fromSide", "toSide"]) {
        if (p[k] === undefined) continue;
        if (p[k] === null) { if (k in e) { delete e[k]; did = true; } }
        else if (["top", "right", "bottom", "left"].includes(p[k]) && e[k] !== p[k]) { e[k] = p[k]; did = true; }
      }
      if (did) changed++;
    }
    if (!styled) for (const n of nodes) if (n && typeof n === "object") for (const k of KEYS) if (typeof n[k] === "number" && isFinite(n[k]) && !Number.isInteger(n[k])) n[k] = Math.round(n[k]);
    const out = serialise(obj) + (styled && trailing ? "\n" : "");
    return { text: out, changed, missing, normalised: !styled };
  }

  const api = { write, arrange, serialise, isObsidianStyle };
  root.LinenCanvasWriter = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : typeof globalThis !== "undefined" ? globalThis : this);
