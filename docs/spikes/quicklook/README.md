# Spike S(a): a Quick Look preview extension from a locally signed build

Run 2026-10-11, macOS 26.5, Xcode 26.6, signed "Apple Development" with the personal team 2U8YZJV343 (automatic signing).

## Question
Will Finder's Quick Look load a view-based preview extension (`com.apple.quicklook.preview`, `QLIsDataBasedPreview` false) from such a build, host a `WKWebView` that runs the renderer's script, and show local images next to the note?

## Answer: yes, with two conditions
1. **Loads and runs script:** registered with `pluginkit -a`, `qlmanage -p` showed the extension's page and its inline script ran (screenshot in the session record).
2. **Local images need two things.** The sandbox gives the extension only the previewed file: siblings were invisible (directory listing failed) and the image was blocked. With `com.apple.security.temporary-exception.files.home-relative-path.read-only` = `/` the extension could list the folder, but `WKWebView` still could not load the file directly, because its web content process has its own sandbox. Serving the image through a `satr-local:` `WKURLSchemeHandler`, which runs in the extension's process, loaded it. Temporary exceptions are acceptable because Satr is not distributed through the Mac App Store.
3. **Cold start:** the first preview right after registering came up blank twice; the second preview rendered. M6 must measure first-preview time after login and after install, and the extension should paint a paper ground immediately.

Entitlements used: app sandbox, `network.client` (included from the start because other Quick Look Markdown extensions use it with WKWebView; not yet tested without it), the home-relative read-only exception.

The spike's extension was unregistered (`pluginkit -r`) and its build removed right after, so it no longer previews Markdown in Finder.
