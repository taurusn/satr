# LinenKit

The non-UI core of Linen: vault detection, the vault index and wiki link resolution, file watching for live reload, text decoding, and the place, baseline and session stores. Swift 6 with strict concurrency, macOS 15, no dependencies, tested with Swift Testing.

```
Sources/LinenKit/
  Vault/    Vault, VaultLocator, VaultIndex, link resolution, note parsing, search
  Watch/    FileWatcher and its helpers (signature, presenter, stable reader)
  Text/     TextDecoder
  Store/    PlaceStore, BaselineStore, SessionStore, FileKey, FileIdentity
  Support/  path canonicalisation and Unicode folding
```

## Running the tests

```
cd LinenKit
swift test                      # 62 tests in 8 suites, about 8 s
swift test -c release -Xswiftc -enable-testing --filter VaultIndexTimingTests   # release timings
```

The watcher and index tests write only to fresh folders under the temporary directory. One timing test reads `~/vault` (read only) and is skipped when it is absent; it prints counts and times, never note text.

## Vault

**`VaultLocator.vault(for:)`** resolves symlinks, then returns the nearest ancestor holding an `.obsidian` folder, else the nearest holding `.git` (a folder or a worktree's `.git` file), else the file's own folder. A `.obsidian` higher up wins over a nearer `.git`, so a repo inside the vault belongs to the vault.

**`VaultIndex`** is an in-memory index of one vault. `build()` walks the vault (skipping hidden folders, `node_modules`, `.git`, `.obsidian`, `.trash`) and parses every `.md` note in parallel: name, aliases from frontmatter (block list, inline list or one string, under `aliases:` or `alias:`), ATX headings outside fenced code, and wiki links (`[[target]]`, `[[target|label]]`, `[[target#heading]]`, `[[target#^block]]`, `![[embed]]`) outside fenced and inline code. Links in frontmatter values are indexed too: 959 of the vault's links live there and Obsidian counts them. Other files are recorded so links to images and PDFs resolve. `update(changed:)` re-reads files or whole folders and drops deleted ones.

Builds and updates run one at a time on a serial background queue and publish an immutable snapshot. Queries take the snapshot under a lock held for one pointer copy and never wait for a build.

| Query | What it returns |
|---|---|
| `resolve(_:from:)` | `LinkResolution`: `.note(url, heading:, block:)`, `.ambiguous([url])` or `.missing(path)` |
| `noteName(for:)` | the file name without extension, else the first alias |
| `search(_:limit:)` | `[NoteRef]` for Open Quickly |
| `backlinks(to:limit:)` | `[Backlink]`, one per source note, with the first linking sentence |
| `backlinkCount(to:)`, `headings(for:)`, `aliases(for:)`, `noteCount` | added for Linked from, the outline and the footer |

**Resolution rules.** Every comparison is Unicode NFC and case folded, and `.md` is optional.

1. Split off `|label` (a `\|` inside a table counts as `|`), then `#heading` or `#^block`. For `#A#B` the heading is `B`. An empty path (`[[#Goals]]`) points at the source note.
2. A path starting with `./` or `../` is relative to the source note's folder and must match exactly. Leaving the vault is missing.
3. A path containing `/` that equals a vault-relative path matches it. A leading `/` allows only this rule.
4. Otherwise every file whose vault-relative path equals `<target>.md` or ends with `/<target>.md` is a candidate. One candidate wins outright. Among several, the file at `<source folder>/<target>.md` wins (for a bare name, the one in the source's own folder); else the single shallowest file (fewest path components) wins; else the link is `.ambiguous` with all candidates sorted by path.
5. Aliases are tried only when no file name matched, with the same tie-breaks.
6. A target ending in another extension (`image.png`) looks for that file by rules 2 to 4 first, then for a note, and returns `.note(url, nil, nil)`.
7. A matched heading comes back as written in the note, so `[[Ferry#goals]]` returns `Goals`.

Each rule has a test on a generated fixture vault: duplicate names in different folders, names differing only by case, NFD-encoded Arabic file names with hamza letters (أ إ آ ؤ ئ, checked as NFD bytes on disk), aliases, Arabic headings in both normal forms, attachments, relative paths and skipped folders.

**Search** matches names and aliases, NFC and case folded, in three tiers: the text starts with the query, a word in it starts with the query, or the query's letters appear in order. Within a tier shorter texts come first, then alphabetical. One result per note; `matchedAlias` says when an alias matched.

**Backlinks** group by source note, sorted by name, leaving out self links. The sentence is the first body sentence holding the link (split at `.`, `!`, `?`, `؟` followed by a space, or at table cell borders), with block markers removed and every wiki link reduced to its label; a link found only in frontmatter gives its `key: value` line.

## FileWatcher

Watches one open document. A vnode source on the parent folder catches replacing saves, and a vnode source on the file (write, extend, delete, rename, attrib, revoke) catches in-place writes. The file source is rearmed whenever the inode at the path changes, and the path is stat'ed again after every arm so a save landing between stat and rearm is caught. A change is a difference in device, inode, size or modification time; reading or tagging a file is not a change. An `NSFilePresenter` sees coordinated writers and moves, and `NSWorkspace.didWakeNotification` triggers a stat after sleep; neither is waited on.

Events, on the queue passed to `init`:

- `.content(data, generation:, inBurst:)`: a read starts 40 ms after the last change, goes through `NSFileCoordinator`, and repeats (up to 5 times) while size or modification time move under it. While changes keep arriving less than 40 ms apart, an intermediate read is delivered at most every 250 ms with `inBurst: true`. `start()` delivers the current content once as generation 0.
- `.quiet(generation:)`: 300 ms after the last change. It is not sent while the file is missing.
- `.missing`: the file has been gone for 500 ms.
- `.moved(url)`: a coordinated move arrives at once through the presenter. An uncoordinated rename or move is found when the 500 ms replace window ends, by asking the kernel for the current path of the descriptor the file source still holds. `url` follows the file.

## TextDecoder

`decode(_:override:)` never fails. Order: a byte order mark (UTF-8, UTF-16 LE or BE); strict UTF-8; UTF-8 with U+FFFD replacements when the bytes are mostly UTF-8 (more valid multi-byte characters than errors); Windows-1256 when there are at least 3 Arabic-range bytes (0xC1 to 0xDA, 0xDC to 0xED) and more of them than Latin accented bytes; else Windows-1252. Undefined bytes become U+FFFD and set `lossy`. `TextDecoder.windowsArabic` names Windows-1256, which `String.Encoding` lacks.

## Stores

JSON files in the directory passed to `init` (the app passes Application Support/Linen): `places.json`, `baselines.json`, `session.json`. Each loads once, saves atomically at most 500 ms after the first unsaved change, and saves at once on `flush()`. A corrupt file starts empty.

- **`PlaceStore`**: a `Place` (block hash and index, offset, quote, zoom, at end, date) per file, least recently used first out, 500 files. Reads count as use.
- **`BaselineStore`**: the acknowledged block hashes per file, 500 files, the first 20,000 hashes per file.
- **`SessionStore`**: `Session { windows: [[TabState]] }`, each tab with bookmark data and its last path.
- **`FileKey.make(for:)`**: `id:<volume UUID>:<file ID>`, else `path:<standardized path>`.
- **`FileIdentity`**: plain (not security-scoped) bookmark data, resolved without UI or mounting, so renamed and moved files are found.

Writers that save by replacing the file (Claude Code's Write and Edit tools, Foundation atomic writes) give it a new file ID, which changes its `FileKey`. So the stores also keep each entry's canonical path, and the URL-based calls (`place(for:)`, `set(_:for:)`, `hashes(for:)`) fall back to the path and move the entry to the new key. The key-based calls match keys exactly.

## Measured on this Mac (2026-10-11, MacBook Air Mac16,12, macOS 26.5.1)

| Measure | Debug (`swift test`) | Release |
|---|---|---|
| Index build, `~/vault` (495 notes, 5,391 links), three runs | 114, 125, 124 ms | 51, 44, 49 ms |
| Index build, generated vault (500 notes, 6,500 links) | 156 ms | 61 ms |
| Index build, `~/vault`, with 10 busy loops loading the CPU | 195 to 238 ms | |
| One resolve + search + backlinks query on 500 notes | 2.2 ms | 1.4 ms |

`~/vault` resolves as 5,339 links to one file, 0 ambiguous, 52 missing.

| Save, write to delivered content | Latency |
|---|---|
| In-place write | 47 ms |
| Foundation atomic write | 42 ms |
| Temp file renamed over | 44 ms |
| Vim style (rename away, write, delete backup) | 48 ms |
| Delete, recreate after 300 ms | 44 ms |
| Coordinated write | 50 ms |
| 20 writes 20 ms apart (in place, atomic) | final read 52 ms and 44 ms after the last write, with 1 or 2 intermediate reads |
| `.quiet` after a write | 302 to 307 ms |
| `.moved`, uncoordinated rename / coordinated move | 505 ms / 3 ms |
| `.missing` after a delete | 505 ms |

## Choices made where the brief left room

- A bare name never uses the root-path rule: `[[Ferry]]` goes through rule 4, where a root-level `Ferry.md` is one candidate. A path with `/` that exists exactly wins first.
- "Shortest path" means fewest path components. Ties are reported as ambiguous with every candidate, so the app can say "Two notes called ...".
- Rule 5 (aliases) follows the brief. The M5 check against Obsidian's `resolvedLinks` should confirm it, since Obsidian may treat a link that only matches an alias as unresolved.
- A burst is a run of changes less than 40 ms apart. A writer that pauses longer between saves gets one `inBurst: false` read per save, so LIVE-2's four reloads a second holds only within continuous bursts; the app can coalesce beyond that.
- The Windows-1256 rule classes each high byte by context, because the two ranges overlap (0xE9 is both "é" and an Arabic-range byte): a byte next to an ASCII letter, or one of the Latin letters Windows-1256 keeps, counts as Latin.
- The index walk does not follow symlinked files or folders.
