// Spike I(a), injected at document start (the page's world). It reads the renderer, never changes it:
// 1. Console capture: console.error, uncaught errors, unhandled rejections and CSP violations go to the app's
//    `console` handler, console.warn to `warn` (the blocks host and board host capture the same set on the Mac).
// 2. A frame recorder for real touches: from the first touch of a gesture to the last finger up it records every
//    animation-frame interval, and for each frame in which the board's view (LinenBoard._state.view) moved, the delay
//    from the earliest input event not yet shown (its event.timeStamp) to that frame. After the fingers lift it
//    records the settle: frames until the renderer stops mounting (S.pumping) or 120 frames.
(() => {
  "use strict";
  const send = (h, m) => { try { window.webkit.messageHandlers[h].postMessage(m); } catch (_) { /* outside the app */ } };
  addEventListener("error", (e) => send("console", "error: " + e.message + " @" + (e.filename || "") + ":" + (e.lineno || "")));
  addEventListener("unhandledrejection", (e) => send("console", "unhandledrejection: " + String((e.reason && (e.reason.stack || e.reason.message)) || e.reason).slice(0, 300)));
  addEventListener("securitypolicyviolation", (e) => send("console", "csp: " + e.violatedDirective + " " + e.blockedURI));
  const ce = console.error, cw = console.warn;
  console.error = (...a) => { send("console", "console.error: " + a.map(String).join(" ").slice(0, 300)); ce.apply(console, a); };
  console.warn = (...a) => { send("warn", a.map(String).join(" ").slice(0, 300)); cw.apply(console, a); };

  const R = (window.__spike = { armed: false, gestures: [], cur: null, settle: null, seq: 0 });
  // Listener timing (diagnosis only): the page's own handlers for touch, pointer and gesture events are wrapped so
  // the time they take inside a gesture is known; behaviour is unchanged (same listener, same this, same return).
  const TIMED = new Set(["touchstart", "touchmove", "touchend", "pointerdown", "pointermove", "pointerup", "gesturestart", "gesturechange", "gestureend"]);
  const wrapped = new WeakMap();
  const add = EventTarget.prototype.addEventListener, remove = EventTarget.prototype.removeEventListener;
  EventTarget.prototype.addEventListener = function (type, fn, o) {
    if (!TIMED.has(type) || typeof fn !== "function") return add.call(this, type, fn, o);
    let w = wrapped.get(fn);
    if (!w) {
      w = function (e) {
        const a = performance.now();
        try { return fn.call(this, e); } finally {
          const g = R.cur;
          if (g) { const d = performance.now() - a; g.js[type] = +((g.js[type] || 0) + d).toFixed(2); if (g.frames.length === 0) g.js0 = +((g.js0 || 0) + d).toFixed(2); }
        }
      };
      wrapped.set(fn, w);
    }
    return add.call(this, type, w, o);
  };
  EventTarget.prototype.removeEventListener = function (type, fn, o) { return remove.call(this, type, (fn && wrapped.get(fn)) || fn, o); };
  const S = () => (window.LinenBoard && window.LinenBoard._state) || null;
  const viewKey = () => { const s = S(); return s && s.view ? s.view.s + "," + s.view.tx + "," + s.view.ty : ""; };
  let prev = 0, last = "", pending = [], running = false;
  // The loop runs only while armed, so it costs nothing in the first-paint and fixture runs.
  R.arm = (on) => { R.armed = !!on; if (R.armed && !running) { running = true; prev = 0; requestAnimationFrame(tick); } return R.armed; };
  function tick() {
    if (!R.armed && !R.cur && !R.settle) { running = false; return; }
    const now = performance.now();
    const v = viewKey();
    const g = R.cur;
    if (g) {
      if (prev) g.frames.push(+(now - prev).toFixed(2));
      if (v !== last) {
        g.moved++;
        if (pending.length) {
          const d = now - pending[0], dl = now - pending[pending.length - 1];
          g.lat.push(+d.toFixed(2));
          g.latLast.push(+dl.toFixed(2));
          if (g.first == null) { g.first = +d.toFixed(2); g.firstLast = +dl.toFixed(2); g.firstAfterStart = +(now - g.t0).toFixed(2); }
        }
        pending = [];
      }
    } else if (R.settle) {
      const st = R.settle;
      if (prev) st.frames.push(+(now - prev).toFixed(2));
      const s = S();
      if (!(s && s.pumping) || st.frames.length >= 120) { st.g.settle = st.frames; st.g.settleMs = +(now - st.t0).toFixed(1); R.settle = null; }
    }
    last = v;
    prev = now;
    requestAnimationFrame(tick);
  }
  const opt = { capture: true, passive: true };
  // WebKit on iOS sends pointerdown before touchstart, so either one starts the gesture.
  const start = (e) => {
    if (!R.armed) return;
    if (!R.cur) {
      if (R.settle) { R.settle.g.settle = R.settle.frames; R.settle.g.settleMs = -1; R.settle = null; }
      const s = S();
      const t = e.target && e.target.closest ? e.target : null;
      R.cur = { n: ++R.seq, t0: e.timeStamp, start: performance.now(), frames: [], lat: [], latLast: [], first: null, queue: [], moved: 0, fingers: 0,
        s0: s && s.view ? s.view.s : null, level0: s ? s.level : null,
        on: t ? (t.closest(".b-node") ? "card" : t.closest(".b-canvas") ? "ground" : "other") : "?", js: {}, js0: 0, downAt: +(performance.now() - e.timeStamp).toFixed(2) };
      pending = [];
    }
    if (e.touches) R.cur.fingers = Math.max(R.cur.fingers, e.touches.length);
    else R.cur.fingers = Math.max(R.cur.fingers, 1);
  };
  add.call(window, "pointerdown", start, opt);
  add.call(window, "touchstart", start, opt);
  for (const type of ["touchmove", "pointermove", "gesturechange"]) add.call(window, type, (e) => {
    if (!R.cur) return;
    pending.push(e.timeStamp);
    if (type === "touchmove") R.cur.queue.push(+(performance.now() - e.timeStamp).toFixed(2));
  }, opt);
  const end = (e) => {
    if (!R.cur || e.touches.length) return;
    const g = R.cur, s = S();
    R.cur = null;
    g.ms = +(performance.now() - g.start).toFixed(1);
    g.s1 = s && s.view ? s.view.s : null;
    g.level1 = s ? s.level : null;
    g.mounted = s && s.mounted ? s.mounted.size : null;
    R.gestures.push(g);
    R.settle = { g, t0: performance.now(), frames: [] };
  };
  // A point on the board's ground (no card under it) near the middle of the view, for pans that start off cards.
  R.groundPoint = () => {
    const C = document.querySelector(".b-canvas");
    if (!C) return null;
    const r = C.getBoundingClientRect(), cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    let best = null, bd = Infinity;
    for (let y = r.top + 200; y < r.bottom - 200; y += 6) for (let x = r.left + 160; x < r.right - 160; x += 6) {
      const el = document.elementFromPoint(x, y);
      if (!el || !C.contains(el) || el.closest(".b-node, .b-zpanel, .b-chip, .b-notecard, .b-line, .b-toast, .b-rail, .b-secl, .b-readlist2, button")) continue;
      const d = Math.hypot(x - cx, (y - cy) * 0.6);
      if (d < bd) { bd = d; best = { x: Math.round(x), y: Math.round(y) }; }
    }
    return best;
  };
  add.call(window, "touchend", end, opt);
  add.call(window, "touchcancel", end, opt);
})();
