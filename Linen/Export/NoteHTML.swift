import CryptoKit
import Foundation
import WebKit

/// Note HTML (PRD-2 EXP-3): one self-contained file with the note as Linen drew it and Loom's styles, that works
/// offline in Safari and Chrome with footnote cards and the Paper / Night switch. Thmanyah is named, never
/// embedded (its licence forbids it; v1 section 11): where it is installed the page shows it, elsewhere the
/// system's faces. Images travel inside the file as data; nothing in it can reach the network.
@MainActor
enum NoteHTML {
    struct Output: Sendable {
        var bytes: Int
        var images: Int
        /// Images that could not be carried (not on this Mac, or remote and never allowed), shown as their text.
        var missingImages: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case read(String), write(String)
        var description: String {
            switch self {
            case let .read(why): String(localized: "Linen could not read this note for HTML: \(why)")
            case let .write(name): String(localized: "Linen could not write \(name)")
            }
        }
    }

    /// Linen's faces by the names Thmanyah installs under, then system faces.
    static let faces: [(String, String)] = [
        ("Linen Sans", "\"thmanyah sans\", -apple-system, \"Segoe UI\", \"Noto Sans Arabic\", sans-serif"),
        ("Linen Serif Display", "\"thmanyah serif display\", Georgia, \"Noto Naskh Arabic\", serif"),
        ("Linen Serif Text", "\"thmanyah serif text\", Georgia, \"Noto Naskh Arabic\", serif"),
    ]

    /// `web` shows the note in Linen's renderer (the tab's own view is fine: nothing on it changes).
    /// `image` returns the bytes and MIME type for a `linen-local:` image source the page uses, or nil.
    static func write(from web: WKWebView, title: String, rendererDirectory: URL, image: (String) -> (Data, String)?, to url: URL) async throws -> Output {
        await NotePDF.prepareRenderer(web)
        let raw: Any?
        do {
            raw = try await web.callAsyncJavaScript(collector, arguments: [:], contentWorld: .world(name: "linen-export-html"))
        } catch {
            throw Failure.read(error.localizedDescription)
        }
        guard let page = raw as? [String: Any], var body = page["html"] as? String else { throw Failure.read("no content") }
        let lang = page["lang"] as? String ?? "en", dir = page["dir"] as? String ?? "ltr"
        let theme = page["theme"] as? String ?? "paper"
        let hasMath = (page["math"] as? Bool) ?? false

        // Images become data, or their text where they cannot travel. Only Linen's own local images are asked for:
        // a remote picture is never fetched for an export, and only image types go into the file.
        var carried = 0, missing = 0
        let types: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml", "image/heic", "image/tiff"]
        // At most 200 pictures and 100 MB of them; replaced in one pass over the markup.
        var budget = 100_000_000, left = 200
        var replacement: [String: String] = [:]
        for src in Set(page["images"] as? [String] ?? []).sorted() where !src.hasPrefix("data:") {
            left -= 1
            if left >= 0, src.hasPrefix("linen-local:"), let (data, mime) = image(src), types.contains(mime.lowercased()),
               data.count <= DisplayList.maxImageBytes, data.count <= budget {
                budget -= data.count
                replacement[escapeAttribute(src)] = "src=\"data:\(mime.lowercased());base64,\(data.base64EncodedString())\""
                carried += 1
            } else {
                replacement[escapeAttribute(src)] = "src=\"\" data-missing=\"1\""
                missing += 1
            }
        }
        if !replacement.isEmpty {
            let re = try! NSRegularExpression(pattern: #"src="([^"]*)""#)
            let ns = body as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                guard let rep = replacement[ns.substring(with: m.range(at: 1))] else { continue }
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + rep
                last = m.range.location + m.range.length
            }
            body = out + ns.substring(from: last)
        }

        var css = ""
        for name in stylesheets(in: rendererDirectory) where name != "fonts.css" && (hasMath || !name.contains("katex")) {
            guard var sheet = try? String(contentsOf: rendererDirectory.appendingPathComponent(name), encoding: .utf8) else { continue }
            if name.contains("katex") { sheet = inlineFonts(sheet, base: rendererDirectory.appendingPathComponent(name).deletingLastPathComponent()) }
            css += "/* \(name) */\n" + sheet + "\n"
        }
        css += exportCSS
        css = rename(css)
        body = renameMarkup(body)
        let html = """
        <!doctype html>
        <html lang="\(escapeAttribute(lang))" dir="\(escapeAttribute(dir))" data-theme="\(theme == "night" ? "night" : "paper")" data-face="sans">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; script-src '\(scriptHash)'; base-uri 'none'; form-action 'none'">
        <meta name="generator" content="Linen">
        <title>\(escapeText(title))</title>
        <style>
        \(css)
        </style>
        </head>
        <body>
        <button id="theme" type="button" aria-label="Paper or Night"></button>
        <main id="pane">
        \(body)
        </main>
        <div id="fncard" class="pop" role="note" hidden></div>
        <script>\(script)</script>
        </body>
        </html>
        """
        do { try Data(html.utf8).write(to: url, options: .atomic) } catch { throw Failure.write(url.lastPathComponent) }
        return Output(bytes: html.utf8.count, images: carried, missingImages: missing)
    }

    /// The renderer's own stylesheets, in the order its page links them.
    static func stylesheets(in dir: URL) -> [String] {
        guard let page = try? String(contentsOf: dir.appendingPathComponent("page.html"), encoding: .utf8) else { return ["page.css"] }
        let re = try! NSRegularExpression(pattern: #"<link[^>]*rel="stylesheet"[^>]*href="([^"]+)""#)
        let ns = page as NSString
        return re.matches(in: page, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// In markup, only styles change: `<style>` blocks (Mermaid's) and font-family values, never the note's text.
    static func renameMarkup(_ s: String) -> String {
        var out = s
        for pattern in [#"(?s)<style[^>]*>.*?</style>"#, #"font-family\s*[:=]\s*("[^"]*"|'[^']*'|&quot;.*?&quot;[^;"]*|[^;">]+)"#] {
            let re = try! NSRegularExpression(pattern: pattern)
            let ns = out as NSString
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let r = Range(m.range, in: out)!
                out.replaceSubrange(r, with: rename(String(out[r])))
            }
        }
        return out
    }

    /// Every Linen face name, quoted or not, becomes the installed Thmanyah family with fallbacks (styles only).
    static func rename(_ s: String) -> String {
        var out = s
        for (linen, stack) in faces.sorted(by: { $0.0.count > $1.0.count }) {
            out = out.replacingOccurrences(of: "\"\(linen)\"", with: stack)
            out = out.replacingOccurrences(of: "&quot;\(linen)&quot;", with: stack.replacingOccurrences(of: "\"", with: "&quot;"))
            out = out.replacingOccurrences(of: linen, with: stack.replacingOccurrences(of: "\"", with: "'"))
        }
        return out
    }

    /// KaTeX's own fonts (SIL OFL) travel as data so math draws offline; only when the note has math.
    private static func inlineFonts(_ css: String, base: URL) -> String {
        let re = try! NSRegularExpression(pattern: #"url\(([^)]+\.(woff2|woff|ttf))\)"#)
        let ns = css as NSString
        var out = css
        for m in re.matches(in: css, range: NSRange(location: 0, length: ns.length)).reversed() {
            let path = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let ext = ns.substring(with: m.range(at: 2))
            guard ext == "woff2", let data = try? Data(contentsOf: base.appendingPathComponent(path)) else { continue }
            let r = Range(m.range, in: out)!
            out.replaceSubrange(r, with: "url(data:font/woff2;base64,\(data.base64EncodedString()))")
        }
        // Drop the woff and ttf fallbacks: every browser that runs this file reads woff2.
        return out.replacingOccurrences(of: #",\s*url\([^)]+\.(woff|ttf)\)\s*format\("[a-z]+"\)"#, with: "", options: .regularExpression)
    }

    static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }

    static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The note's header and blocks as shown, minus Linen's own controls; links that only Linen can follow become
    /// text; web links stay.
    static let collector = """
    const header = document.getElementById('note-header'), doc = document.getElementById('doc');
    if (!doc) return { html: '' };
    const box = document.createElement('div');
    if (header && !header.hidden) box.appendChild(header.cloneNode(true));
    const d = doc.cloneNode(true);
    d.classList.remove('pre-open');
    d.querySelectorAll('.copy, button, .gap, .blocked button, mark.find, .lnote-card').forEach(n => { if (n.matches('mark.find')) n.replaceWith(...n.childNodes); else n.remove(); });
    // NOTE-3: the numbered sources and their marks, which the reader keeps for print, travel with the file.
    d.querySelectorAll('.lnotes-blk[hidden], .lnote-num[hidden]').forEach(n => n.removeAttribute('hidden'));
    d.querySelectorAll('.chg').forEach(n => n.classList.remove('chg'));
    d.querySelectorAll('a[href]').forEach(a => {
      const h = a.getAttribute('href') || '';
      if (/^https?:/i.test(h)) { a.setAttribute('rel', 'noopener noreferrer'); return; }
      if (h.startsWith('#')) return;
      a.removeAttribute('href'); a.classList.add('nolink');
    });
    d.querySelectorAll('[data-src]').forEach(n => n.removeAttribute('data-src'));
    box.appendChild(d);
    const images = [...box.querySelectorAll('img[src]')].map(i => i.getAttribute('src'));
    const html = document.documentElement;
    return { html: box.innerHTML, images, lang: html.lang || 'en', dir: (doc.getAttribute('dir') || html.dir || 'ltr'), theme: html.dataset.theme || 'paper',
             math: !!box.querySelector('.katex') };
    """

    /// Export-only rules: no reader chrome, the column centred, the theme button and the footnote card.
    static let exportCSS = """
    /* Linen export */
    body { padding: 40px 0 60px; }
    #pane { margin: 0 auto !important; padding: 0 22px; max-width: calc(var(--measure) + 44px); }
    #doc > .blk.wide { max-width: min(calc(var(--col) + 2 * var(--wing)), 100%); }
    #doc a.nolink { border-bottom: 0; color: inherit; }
    #doc img[data-missing] { display: none; }
    #theme { position: fixed; top: 12px; inset-inline-end: 14px; font: 500 12px var(--sans); color: var(--head); background: var(--ground);
      border: 1px solid var(--line); border-radius: 2px; padding: 5px 10px; cursor: pointer; z-index: 8; }
    #fncard { position: absolute; max-width: min(380px, 86vw); padding: 10px 14px; font: 400 14px/1.55 var(--body-face); color: var(--text); z-index: 9; }
    #fncard p { margin: 0; }
    #fncard .back { display: none; }
    @media print { #theme, #fncard { display: none !important; } body { padding: 0; } #pane { max-width: none; padding: 0; } }
    @media (max-width: 500px) { #pane { padding: 0 16px; } }
    """

    /// Only Linen's own script runs in the file: the policy names it by hash, so an inline handler or script that
    /// came with the note's markup does not.
    static var scriptHash: String { "sha256-" + Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString() }

    /// Paper / Night (following the system until chosen, remembered when it can be) and footnote cards on hover,
    /// focus or tap. No network, no other storage.
    static let script = """
    (function () {
      var html = document.documentElement, btn = document.getElementById('theme');
      var key = 'linen-theme', mq = window.matchMedia ? matchMedia('(prefers-color-scheme: dark)') : null, chosen = null;
      try { chosen = localStorage.getItem(key); } catch (e) {}
      function apply() { var t = chosen || (mq && mq.matches ? 'night' : 'paper'); html.dataset.theme = t; btn.textContent = t === 'night' ? 'Paper' : 'Night'; }
      btn.addEventListener('click', function () { chosen = html.dataset.theme === 'night' ? 'paper' : 'night'; try { localStorage.setItem(key, chosen); } catch (e) {} apply(); });
      if (mq && mq.addEventListener) mq.addEventListener('change', apply);
      apply();
      var card = document.getElementById('fncard'), open = null, timer = 0;
      function show(a) {
        var id = (a.getAttribute('href') || '').slice(1), li = id && document.getElementById(id);
        if (!li) return;
        card.innerHTML = li.innerHTML; card.hidden = false; open = a;
        var r = a.getBoundingClientRect(), w = card.offsetWidth, x = Math.min(Math.max(8, r.left + scrollX - w / 2), scrollX + innerWidth - w - 8);
        card.style.left = x + 'px'; card.style.top = (r.bottom + scrollY + 6) + 'px';
      }
      function hide() { card.hidden = true; open = null; }
      document.querySelectorAll('sup.fnref a').forEach(function (a) {
        a.addEventListener('mouseenter', function () { clearTimeout(timer); timer = setTimeout(function () { show(a); }, 300); });
        a.addEventListener('mouseleave', function () { clearTimeout(timer); timer = setTimeout(hide, 200); });
        a.addEventListener('focus', function () { show(a); });
        a.addEventListener('blur', hide);
        a.addEventListener('click', function (e) { if (matchMedia('(hover: none)').matches) { e.preventDefault(); open === a ? hide() : show(a); } });
      });
      card.addEventListener('mouseenter', function () { clearTimeout(timer); });
      card.addEventListener('mouseleave', hide);
      document.addEventListener('keydown', function (e) { if (e.key === 'Escape') hide(); });
    })();
    """
}
