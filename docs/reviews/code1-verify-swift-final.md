# Linen code review 1, Swift verification, Codex

## Verdicts

1. **FIXED** — outside grants are request-specific and bound to canonical path plus device/inode; serving revalidates identity. [DocumentWindow.swift:503](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:503), [Schemes.swift:235](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:235)

2. **DISAGREE-ACCEPTED** — the PRD reading is correct. Links are canonicalized; Markdown/text opens in Linen regardless of vault boundary, while other outside or executable files require confirmation. Wiki, ordinary, ambiguous, and image links use this gate. [DocumentWindow.swift:316](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:316), [DocumentWindow.swift:349](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:349), [PRD.md:223](/Users/hatim/Developer/Satr/docs/PRD.md:223)

3. **SKIPPED** — renderer scope.

4. **FIXED** — responses are streamed, MIME/status/size checked, cut off over 10 MB, and stopped tasks are canceled and suppressed. [Schemes.swift:358](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:358), [Schemes.swift:421](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:421), [Schemes.swift:447](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:447)

5. **FIXED** — approval is per document, combined with the global preference, and reset on document replacement. [DocumentWindow.swift:183](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:183), [DocumentWindow.swift:280](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:280), [DocumentWindow.swift:403](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:403)

6. **FIXED** — local name/bytes must agree, pixel arithmetic is overflow-safe, and bounded SVGs are rasterized. [Schemes.swift:147](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:147), [Schemes.swift:160](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:160), [Schemes.swift:194](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:194)

7. **FIXED** — `hops < 8` prevents a ninth dereference. [Schemes.swift:61](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:61), [Schemes.swift:72](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:72)

8. **SKIPPED** — renderer scope.

9. **SKIPPED** — renderer scope.

10. **SKIPPED** — renderer scope.

11. **SKIPPED** — renderer scope.

12. **SKIPPED** — renderer scope.

13. **SKIPPED** — renderer scope.

14. **PARTLY FIXED** — move handling now updates URL, vault, index, title, reloads fully, and flushes dirty indexes on quiet. Missing: encoding overrides are keyed by path and are not migrated, so a moved file’s menu shows Automatic and a relaunch can decode differently. [DocumentWindow.swift:153](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:153), [DocumentWindow.swift:163](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:163), [DocumentWindow.swift:929](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:929)

15. **FIXED** — probing, descriptor reads, and decoding now run off-main; the live set suppresses responses after `stop`. [DocumentWindow.swift:474](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:474), [Schemes.swift:292](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:292), [Schemes.swift:315](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:315)

16. **PARTLY FIXED** — missing tabs, front-only construction, encoding controls, states, and network polling exist. Missing: after a denied folder or disconnected volume becomes available, only the watcher restarts; the vault/index computed while unavailable is not recomputed. [AppDelegate.swift:132](/Users/hatim/Developer/Satr/Linen/App/AppDelegate.swift:132), [Menus.swift:67](/Users/hatim/Developer/Satr/Linen/App/Menus.swift:67), [DocumentWindow.swift:541](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:541), [FileWatcher.swift:208](/Users/hatim/Developer/Satr/LinenKit/Sources/LinenKit/Watch/FileWatcher.swift:208)

17. **PARTLY FIXED** — LinenKit decoding is used and baseline is omitted. However, readiness and first-paint waits time out and open their gates; a load can be sent before `ready`, fail without retry, and still report preparation complete. The network entitlement matches amended QL-1. [PreviewViewController.swift:54](/Users/hatim/Developer/Satr/LinenQuickLook/PreviewViewController.swift:54), [PreviewViewController.swift:95](/Users/hatim/Developer/Satr/LinenQuickLook/PreviewViewController.swift:95), [LinenQuickLook.entitlements:7](/Users/hatim/Developer/Satr/LinenQuickLook/LinenQuickLook.entitlements:7)

18. **FIXED** for native parts — default-reader confirmation separates plain text, Welcome shows 12 recents, and the native bridge accepts guarded swipe commands. [AppDelegate.swift:196](/Users/hatim/Developer/Satr/Linen/App/AppDelegate.swift:196), [Welcome.swift:39](/Users/hatim/Developer/Satr/Linen/Panels/Welcome.swift:39), [DocumentWindow.swift:287](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:287)

## New defects

1. **Blocker — local-image work is unbounded and not actually canceled.** Every request launches a detached load; the 200 MB budget is checked only after the complete file has been read and decoded, while `stop` merely suppresses delivery. A document referencing many 50 MB images can consume massive I/O/RSS even after navigation. [Schemes.swift:292](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:292), [Schemes.swift:303](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:303), [Schemes.swift:315](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:315)

2. **Major — recovered tabs retain the wrong vault authority.** With a volume absent or folder denied at launch, `vault` and `index` are initialized from the inaccessible path. Reconnection only restarts watching, so sibling wiki links and in-vault images remain unresolved until reopening/navigation. [DocumentWindow.swift:48](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:48), [DocumentWindow.swift:541](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:541)

3. **Major — Quick Look’s gate loses concurrent waiters.** `Gate` stores one continuation. Two cold previews before `ready` overwrite the first continuation; its task can hang permanently. A readiness timeout can also cause a permanently blank preview because failed sends are not retried. [PreviewViewController.swift:98](/Users/hatim/Developer/Satr/LinenQuickLook/PreviewViewController.swift:98), [PreviewViewController.swift:107](/Users/hatim/Developer/Satr/LinenQuickLook/PreviewViewController.swift:107)

4. **Major — printing has one process-wide retained context.** Starting prints from two windows overwrites `PrintContext.live`; either completion then clears the other context, risking a lost callback, premature release, or concurrent-print exception. [Printer.swift:24](/Users/hatim/Developer/Satr/Linen/Print/Printer.swift:24), [Printer.swift:31](/Users/hatim/Developer/Satr/Linen/Print/Printer.swift:31), [Printer.swift:50](/Users/hatim/Developer/Satr/Linen/Print/Printer.swift:50)

5. **Moderate — vault-index updates capture mutable actor state across suspension.** The move task captures `oldIndex` but reads `index` after awaiting. Move a file, then navigate to another vault before that await returns: the new-file update targets the later vault index and is skipped. [DocumentWindow.swift:170](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:170)

Stopped scheme tasks are not answered; the remaining local-scheme defect is continued work after stopping.
