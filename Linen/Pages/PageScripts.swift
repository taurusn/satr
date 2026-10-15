import Foundation

/// Scripts Linen runs in a sealed page's isolated world (PAGE-3, PAGE-8). The page's own scripts cannot see this
/// world's globals or its message handler; they share only the DOM. Linen talks to the page by setting attributes
/// and dispatching events.
enum PageScripts {
    /// The isolated world: real clicks on links (isTrusted only) in every frame; in the main frame, the theme,
    /// note cards for `data-note` elements in kit pages, the place for reloads (PAGE-5), and a ping the stall
    /// watchdog uses (PAGE-12).
    static func kit(theme: String) -> String {
        """
        (() => {
          const post = (m) => { try { webkit.messageHandlers.linenKit.postMessage(m); } catch (e) {} };
          const linkOf = (e) => {
            const path = e.composedPath ? e.composedPath() : [e.target];
            for (const n of path) {
              if (!n || n.nodeType !== 1) continue;
              const name = n.localName;
              if ((name === 'a' || name === 'area') && (n.hasAttribute('href') || n.hasAttribute('xlink:href'))) return n;
            }
            return null;
          };
          const onClick = (e) => {
            if (!e.isTrusted) return;
            if (e.type === 'auxclick' && e.button !== 1) return;
            if (e.type === 'click' && e.button !== 0) return;
            const a = linkOf(e); if (!a) return;
            let raw = a.href; if (raw && typeof raw === 'object') raw = raw.baseVal;
            if (!raw) raw = a.getAttribute('href') || a.getAttribute('xlink:href') || '';
            let abs = ''; try { abs = new URL(raw, document.baseURI).href; } catch (x) { abs = String(raw); }
            post({type: 'click', href: abs, main: window === top, newTab: !!(e.metaKey || e.button === 1)});
          };
          window.addEventListener('click', onClick, true);
          window.addEventListener('auxclick', onClick, true);
          if (window !== top) return;

          let theme = \(jsString(theme));
          const root = () => document.documentElement;
          const applyTheme = () => { if (root()) root().setAttribute('data-linen-theme', theme); };
          applyTheme();
          if (!root()) document.addEventListener('readystatechange', applyTheme, {once: true});

          // Note cards (PAGE-3): hover 300 ms with a pointer, tap on a touch screen, or focus; Esc closes.
          let host = null, card = null, timer = 0, current = null;
          const usesKit = () => !!document.querySelector('link[href^="linen-kit:"]');
          const noteText = (el) => {
            const v = el.getAttribute('data-note') || '';
            if (v.startsWith('#')) { const t = document.getElementById(v.slice(1)); if (t) return (t.content || t).textContent || ''; }
            return v;
          };
          const ensure = () => {
            if (card) return;
            host = document.createElement('linen-note');
            host.style.cssText = 'all: initial; position: fixed; left: 0; top: 0; z-index: 2147483647; pointer-events: none;';
            const shadow = host.attachShadow({mode: 'closed'});
            card = document.createElement('div');
            card.setAttribute('role', 'tooltip');
            shadow.append(card);
            (document.body || root()).append(host);
          };
          const show = (el) => {
            const text = noteText(el).trim(); if (!text) return;
            ensure(); current = el;
            const night = theme === 'night';
            card.style.cssText = [
              'position: fixed', 'max-width: 320px', 'padding: 12px 14px', 'border-radius: 2px',
              'font: 400 14px/1.5 "Linen Sans", -apple-system, sans-serif', 'white-space: normal',
              night ? 'background: #284734; color: #F6F3EB; border: 1px solid rgba(246,243,235,.14)'
                    : 'background: #FBF9F4; color: #1F3328; border: 1px solid #DAD5C8',
              'box-shadow: 0 8px 24px rgba(31,51,40,.16)', 'pointer-events: auto',
            ].join(';');
            card.replaceChildren();
            const title = el.getAttribute('data-note-title');
            if (title) { const h = document.createElement('div'); h.textContent = title; h.style.cssText = 'font-weight: 500; margin-bottom: 4px'; card.append(h); }
            for (const para of text.split(/\\n\\s*\\n/)) { const p = document.createElement('p'); p.textContent = para; p.style.margin = '0 0 6px'; card.append(p); }
            card.dir = getComputedStyle(el).direction;
            const r = el.getBoundingClientRect(), w = Math.min(320, innerWidth - 16);
            card.style.width = w + 'px';
            const h = card.getBoundingClientRect().height;
            let x = r.right + 10, y = r.top;
            if (x + w > innerWidth - 8) x = r.left - 10 - w;
            if (x < 8) { x = Math.max(8, Math.min(r.left, innerWidth - w - 8)); y = r.bottom + 8; if (y + h > innerHeight - 8) y = r.top - 8 - h; }
            y = Math.max(8, Math.min(y, innerHeight - h - 8));
            card.style.left = x + 'px'; card.style.top = y + 'px';
            post({type: 'note', shown: true});
          };
          const hide = () => { clearTimeout(timer); if (card) card.style.display = 'none'; current = null; };
          const noteOf = (t) => t && t.closest ? t.closest('[data-note]') : null;
          document.addEventListener('pointerover', (e) => {
            if (!e.isTrusted || !usesKit()) return;
            const el = noteOf(e.target); if (!el || el === current) return;
            clearTimeout(timer);
            if (e.pointerType === 'mouse') timer = setTimeout(() => show(el), 300);
          }, true);
          document.addEventListener('pointerout', (e) => {
            if (!e.isTrusted) return;
            const to = e.relatedTarget; if (current && to && (current.contains(to) || to === host)) return;
            if (noteOf(e.target)) hide();
          }, true);
          document.addEventListener('pointerup', (e) => {
            if (!e.isTrusted || e.pointerType === 'mouse' || !usesKit()) return;
            const el = noteOf(e.target); if (el) { el === current ? hide() : show(el); }
          }, true);
          document.addEventListener('focusin', (e) => { const el = noteOf(e.target); if (el && usesKit()) show(el); }, true);
          document.addEventListener('focusout', () => hide(), true);
          document.addEventListener('keydown', (e) => { if (e.key === 'Escape') hide(); }, true);
          addEventListener('scroll', () => hide(), true);

          // What Linen asks of the page, reachable only from this world.
          window.__linenKit = {
            setTheme(t) { theme = t; applyTheme(); hide(); try { document.dispatchEvent(new CustomEvent('linen:theme', {detail: t})); } catch (e) {} return t; },
            ping() { return 1; },
            place() {
              const doc = document.scrollingElement || root();
              const max = Math.max(1, doc.scrollHeight - innerHeight);
              let best = null, bestTop = Infinity;
              for (const el of document.querySelectorAll('[id]')) {
                const t = el.getBoundingClientRect().top;
                if (t >= -2 && t < bestTop) { best = el; bestTop = t; }
              }
              return {id: best ? best.id : null, top: best ? bestTop : 0, frac: doc.scrollTop / max};
            },
            restore(p) {
              const doc = document.scrollingElement || root();
              const el = p && p.id ? document.getElementById(p.id) : null;
              if (el) { doc.scrollTop += el.getBoundingClientRect().top - (p.top || 0); return 'id'; }
              if (p) doc.scrollTop = p.frac * Math.max(0, doc.scrollHeight - innerHeight);
              return 'frac';
            },
            looksEmpty() {
              const text = (document.body ? document.body.innerText : '').trim();
              return text.length < 40 && document.querySelectorAll('script').length > 0;
            },
            title() { return document.title || ''; },
          };
        })();
        """
    }

    static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    /// The inventory walk (PAGE-10), as a function source that runs in any realm (page, frame, worker, shared
    /// worker, worklet): every own property descriptor of the global object, of every constructor and prototype
    /// reachable from the globals and from the prototype chains of the objects a page can reach without creating
    /// anything, and of those objects themselves, two levels deep. Names and descriptor shapes only, never values.
    /// Returns sorted lines.
    static let inventoryFunction = """
    function linenInventory() {
      const out = new Set();
      const seen = new WeakSet();
      const G = globalThis;
      const kind = (d) => {
        if ('value' in d) { const v = d.value; return 'v:' + (v === null ? 'null' : typeof v) + (d.writable ? 'w' : '') + (d.enumerable ? 'e' : '') + (d.configurable ? 'c' : ''); }
        return 'a:' + (d.get ? 'g' : '') + (d.set ? 's' : '') + (d.enumerable ? 'e' : '') + (d.configurable ? 'c' : '');
      };
      const key = (k) => typeof k === 'symbol' ? '@' + String(k.description) : String(k);
      const isObj = (v) => v !== null && (typeof v === 'object' || typeof v === 'function');
      const protoName = (p) => {
        try { const d = Object.getOwnPropertyDescriptor(p, 'constructor'); if (d && typeof d.value === 'function' && d.value.name) return d.value.name + '.prototype'; } catch (e) {}
        try { const t = p[Symbol.toStringTag]; if (typeof t === 'string') return t + '.proto'; } catch (e) {}
        return null;
      };
      const own = (obj, label) => {
        let keys; try { keys = Reflect.ownKeys(obj); } catch (e) { out.add(label + ' !keys'); return []; }
        const found = [];
        for (const k of keys) {
          let d; try { d = Object.getOwnPropertyDescriptor(obj, k); } catch (e) { continue; }
          if (!d) continue;
          out.add(label + '.' + key(k) + ' ' + kind(d));
          found.push([k, d]);
        }
        return found;
      };
      const chain = (obj, fallback) => {
        let p; try { p = Object.getPrototypeOf(obj); } catch (e) { return; }
        let depth = 0;
        while (p && depth < 12) {
          if (!seen.has(p)) { seen.add(p); const n = protoName(p) || (fallback + '^' + depth); own(p, n); }
          try { p = Object.getPrototypeOf(p); } catch (e) { break; }
          depth++;
        }
      };
      const iface = (fn, label) => {
        if (seen.has(fn)) return; seen.add(fn);
        own(fn, label);
        let proto; try { proto = fn.prototype; } catch (e) {}
        if (isObj(proto) && !seen.has(proto)) { seen.add(proto); own(proto, (fn.name || label) + '.prototype'); chain(proto, label); }
        chain(fn, label);
      };
      // Another realm's window (a frame's parent or top) is that realm's own inventory, not this one's.
      const otherWindow = (v) => { try { return v !== G && v.window === v; } catch (e) { return true; } };
      const object = (obj, label, levels) => {
        if (!isObj(obj) || seen.has(obj)) return;
        if (otherWindow(obj)) { out.add(label + ' =window'); return; }
        seen.add(obj);
        const props = own(obj, label);
        chain(obj, label);
        for (const [k, d] of props) { if ('value' in d && typeof d.value === 'function') iface(d.value, label + '.' + key(k)); }
        if (levels <= 0) return;
        // Every property the object answers to, own or from its prototypes, read off the instance.
        const names = new Set();
        let p = obj, n = 0;
        while (p && n < 12 && p !== Object.prototype) { try { for (const k of Reflect.ownKeys(p)) names.add(k); } catch (e) {} try { p = Object.getPrototypeOf(p); } catch (e) { break; } n++; }
        for (const k of names) {
          let v; try { v = obj[k]; } catch (e) { continue; }
          if (typeof v === 'function') continue;
          if (isObj(v)) object(v, label + '.' + key(k), levels - 1);
        }
      };
      seen.add(G);
      const top = own(G, 'G');
      chain(G, 'G');
      for (const [k, d] of top) {
        if ('value' in d && typeof d.value === 'function') iface(d.value, key(k));
      }
      for (const [k, d] of top) {
        if ('value' in d && isObj(d.value) && typeof d.value !== 'function') object(d.value, 'G.' + key(k), 2);
      }
      // Objects the global hands out through accessors on itself or its prototypes (navigator, document, ...).
      const names = new Set();
      let p = G, n = 0;
      while (p && n < 12) { try { for (const k of Reflect.ownKeys(p)) names.add(k); } catch (e) {} try { p = Object.getPrototypeOf(p); } catch (e) { break; } n++; }
      for (const k of names) {
        let d = null, q = G; while (q && !d) { try { d = Object.getOwnPropertyDescriptor(q, k); } catch (e) {} q = Object.getPrototypeOf(q); }
        if (!d || !d.get) continue;
        let v; try { v = G[k]; } catch (e) { continue; }
        if (isObj(v) && typeof v !== 'function') object(v, 'G.' + key(k), 2);
      }
      return Array.from(out).sort();
    }
    """
}
