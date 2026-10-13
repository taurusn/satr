# Building Linen

## Tools

- macOS 15 or later, Xcode 26 with its command line tools.
- XcodeGen (`brew install xcodegen`). `Linen.xcodeproj` is generated from `project.yml` and never committed.
- Signing uses the personal team in `project.yml` (automatic, "Apple Development").

## Commands

| Command | What it does |
| --- | --- |
| `make gen` | Generates `Linen.xcodeproj` |
| `make build` | Debug build of the app and its Quick Look extension |
| `make release` | Release build |
| `make run` | Debug build, then opens it |
| `make test` | LinenKit's tests (`swift test`) |
| `make harness` | Builds `build/harness`, which drives the renderer in an offscreen WKWebView |
| `make corpus` | Renders every note in `~/vault` and `~/Desktop/ferry/docs`; reports problems and timings |
| `make reload` | Rewrites a copy of the Ferry PRD 30 times and measures how far the reading line drifts |
| `make lint` | Checks that the page and the app use only the design tokens |
| `make install` | Release build copied to `/Applications/Linen.app` and verified with `codesign` |

## Fonts

`Scripts/copy-renderer.sh` copies the renderer into each bundle and the six Thmanyah faces from `~/Library/Fonts` beside it. The faces are not in the source tree; whether they go into a repository is Hatim's call (their license forbids hosting them publicly).

## Quick Look

The extension is registered when the app is installed. During development:

```sh
pluginkit -a build/DerivedData/Build/Products/Debug/Linen.app/Contents/PlugIns/LinenQuickLook.appex
qlmanage -r
qlmanage -p some-note.md
```

`qlmanage -p` opens its window behind other apps; WebKit draws nothing in a hidden window, so bring it to the front before judging the preview. The extension logs to the unified log: `/usr/bin/log show --last 2m --info --predicate 'subsystem == "com.hatim.linen.quicklook"'` (in zsh, `log` alone is a builtin).

## Strings

Interface strings are in `Linen/Resources/Localizable.xcstrings` with Arabic beside English; `docs/loc/ar-translations.json` keeps the Arabic for every key so the catalog can be refilled after keys change.
