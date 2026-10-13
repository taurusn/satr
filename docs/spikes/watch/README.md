# Spike S(b): what sees each kind of save

Run 2026-10-11, macOS 26.5, APFS. `watch.swift` watches one note three ways at once: a vnode source on the open file, a vnode source on its folder, and an `NSFilePresenter` (Satr 1.2.1's only signal). Raw log: `results-raw.txt` (the case labels were lost from the file because the watcher and the labels shared it; the order below is the order the cases ran, matched by inode changes and timing).

| Save | File vnode | Folder vnode | NSFilePresenter | Inode |
|---|---|---|---|---|
| In-place write (`>`) | fires at once | silent | `didChange` 1.06 s later | same |
| Foundation atomic write | silent (watches the old inode) | fires at once | `didChange` 1.06 s later | new |
| Write a temp file, `mv` over | silent | fires at once | `didChange` 1.07 s later | new |
| Vim style (rename away, write new, delete backup) | silent, then the file is gone | fires at once (twice) | `didChange` 1.07 s later | new |
| Delete, recreate after 300 ms | `delete` | fires at once, twice | `didChange` 1.05 s after the recreate (never a deletion) | new |
| Coordinated write (`NSFileCoordinator`) | fires at once | silent | `didChange` 0.53 s later | same |
| Claude Code's Write tool, then its Edit tool | silent | fires at once | `didChange` 1.06 s later | new each time |

## What it means

- Satr 1.2.1 reloads about one second after a save because the presenter is its only signal. LIVE-1's 150 ms needs the vnode sources.
- Most writers, including the agent tools that rewrite PRDs, replace the file. A vnode source on the open file goes deaf after the first such save; the folder source always fires. Design: watch the folder, on each folder event stat the path, compare the inode and size and modification time with the last seen, rearm the file source on the new inode, and treat a missing file as "maybe being replaced" for 500 ms before showing the missing page.
- Keep the presenter for coordinated writers and for moves (rename of the open file to a new name), but never wait for it.
- Read after a quiet period of 40 ms, and re-read if the size or modification time changed during the read (partial writes).
