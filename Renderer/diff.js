// Block diffs for Linen's page (PRD LIVE-4, LIVE-5): matching two sequences of content hashes, and pairing the
// unmatched blocks between two matches into edits. Pure functions, shared by reloads, change marks and the
// reload announcement; loaded before page.js.
(function (root) {
  "use strict";

  // Matched index pairs [i, j] between hash sequences a and b, in order. Equal runs at both ends match first; the
  // middle is Myers' linear-space form (divide at the middle snake), which keeps two vectors of 2D + 3 numbers
  // instead of one vector per edit step, so 10,000 replaced blocks cost kilobytes, not hundreds of megabytes.
  // Equal blocks match in order, so repeated blocks are deterministic. A middle that needs more than maxD edits
  // counts as replaced (bounded work).
  function diff(a, b, maxD = 4000) {
    const n = a.length, m = b.length;
    let s = 0;
    while (s < n && s < m && a[s] === b[s]) s++;
    let e = 0;
    while (e < n - s && e < m - s && a[n - 1 - e] === b[m - 1 - e]) e++;
    const pairs = [];
    for (let i = 0; i < s; i++) pairs.push([i, i]);
    if (s < n - e && s < m - e) {
      const dmax = Math.min(Math.ceil((n + m - 2 * (s + e)) / 2), Math.ceil(maxD / 2)) + 1;
      const off = dmax + 1;
      const vf = new Int32Array(2 * off + 1), vb = new Int32Array(2 * off + 1);
      const mid = [];
      if (lcs(a, s, n - e, b, s, m - e, mid, vf, vb, off, dmax)) for (const p of mid) pairs.push(p);
    }
    for (let k = 0; k < e; k++) pairs.push([n - e + k, m - e + k]);
    return pairs;
  }

  function lcs(a, a0, a1, b, b0, b1, out, vf, vb, off, dmax) {
    while (a0 < a1 && b0 < b1 && a[a0] === b[b0]) out.push([a0++, b0++]);
    let tail = 0;
    while (a1 - tail > a0 && b1 - tail > b0 && a[a1 - 1 - tail] === b[b1 - 1 - tail]) tail++;
    a1 -= tail; b1 -= tail;
    if (a0 < a1 && b0 < b1) {
      const snake = middleSnake(a, a0, a1 - a0, b, b0, b1 - b0, vf, vb, off, dmax);
      if (!snake) return false;
      const [x0, y0, x1, y1] = snake;
      if (!lcs(a, a0, a0 + x0, b, b0, b0 + y0, out, vf, vb, off, dmax)) return false;
      for (let i = 0; i < x1 - x0; i++) out.push([a0 + x0 + i, b0 + y0 + i]);
      if (!lcs(a, a0 + x1, a1, b, b0 + y1, b1, out, vf, vb, off, dmax)) return false;
    }
    for (let i = 0; i < tail; i++) out.push([a1 + i, b1 + i]);
    return true;
  }

  // The middle snake of an N by M edit graph (Myers 1986, section 4b): forward from the start and backward from
  // the end until the paths overlap. Returns [x0, y0, x1, y1] relative to a0 and b0, or null past dmax.
  function middleSnake(a, a0, N, b, b0, M, vf, vb, off, dmax) {
    const delta = N - M, odd = (delta & 1) !== 0;
    vf[off + 1] = 0;
    vb[off + 1] = 0;
    const limit = Math.min(Math.ceil((N + M) / 2), dmax);
    for (let d = 0; d <= limit; d++) {
      for (let k = -d; k <= d; k += 2) {
        let x = (k === -d || (k !== d && vf[off + k - 1] < vf[off + k + 1])) ? vf[off + k + 1] : vf[off + k - 1] + 1;
        let y = x - k;
        const sx = x, sy = y;
        while (x < N && y < M && a[a0 + x] === b[b0 + y]) { x++; y++; }
        vf[off + k] = x;
        const r = delta - k;
        if (odd && r >= 1 - d && r <= d - 1 && x + vb[off + r] >= N) return [sx, sy, x, y];
      }
      for (let k = -d; k <= d; k += 2) {
        let u = (k === -d || (k !== d && vb[off + k - 1] < vb[off + k + 1])) ? vb[off + k + 1] : vb[off + k - 1] + 1;
        let v = u - k;
        const su = u, sv = v;
        while (u < N && v < M && a[a0 + N - 1 - u] === b[b0 + M - 1 - v]) { u++; v++; }
        vb[off + k] = u;
        const r = delta - k;
        if (!odd && r >= -d && r <= d && vf[off + r] + u >= N) return [N - u, M - v, N - su, M - sv];
      }
    }
    return null;
  }

  // Edited blocks (LIVE-4): between two matched blocks, unmatched old and new blocks pair in order when they are
  // the same kind and the words they share (counted as multisets) make up at least half of each block's words.
  const WORD = /[\p{L}\p{N}]+/gu;
  function wordsOf(b) {
    const counts = new Map();
    let total = 0;
    for (const w of (b.kind === "plain" ? b.text : (b.token.raw || "")).toLowerCase().match(WORD) || []) {
      counts.set(w, (counts.get(w) || 0) + 1);
      total++;
    }
    return { counts, total };
  }
  const kindOf = (b) => (b.kind === "plain" ? "plain" : b.token.type + (b.token.depth ? b.token.depth : ""));
  function similar(x, y) {
    const [small, big] = x.counts.size <= y.counts.size ? [x.counts, y.counts] : [y.counts, x.counts];
    let shared = 0;
    for (const [w, c] of small) shared += Math.min(c, big.get(w) || 0);
    return shared >= Math.max(1, x.total / 2) && shared >= Math.max(1, y.total / 2);
  }
  function pairEdited(oldB, newB, pairs) {
    const out = new Map();
    const words = new Map();
    const of = (b) => { let w = words.get(b); if (!w) words.set(b, (w = wordsOf(b))); return w; };
    const bounds = [[-1, -1], ...pairs, [oldB.length, newB.length]];
    for (let k = 0; k + 1 < bounds.length; k++) {
      const [o0, n0] = bounds[k], [o1, n1] = bounds[k + 1];
      // Each old block looks ahead (up to 64 new blocks) for its edited form, so a block inserted before an edit
      // does not hide it; pairs stay in order.
      let j = n0 + 1;
      for (let i = o0 + 1; i < o1 && j < n1; i++) {
        for (let k = j; k < n1 && k < j + 64; k++) {
          if (kindOf(oldB[i]) !== kindOf(newB[k]) || !similar(of(oldB[i]), of(newB[k]))) continue;
          out.set(i, k);
          j = k + 1;
          break;
        }
      }
    }
    return out;
  }

  root.LinenDiff = { diff, pairEdited };
})(typeof self !== "undefined" ? self : globalThis);
