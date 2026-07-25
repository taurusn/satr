# Satr

Satr is Hatim's local macOS Markdown reader. It opens `.md`, `.markdown`, `.mdown`, and `.mkd` files, renders GitHub-flavored Markdown and Mermaid diagrams, follows local links, resolves Obsidian-style wiki links, and reloads when the source file changes.

Documents use native macOS tabs. Open several files in one window, reorder tabs by dragging, or drag a tab outside the tab bar to give it its own window. Drag it back onto another Satr tab bar to merge it by hand, or choose **Window > Merge All Windows**. Single-document windows keep their tab bar visible so there is always a drop target. `Command-T` opens a document in a new tab, `Command-N` opens one in a separate window, and Control-Tab moves between tabs.

## Build

```sh
npm install
mkdir -p Resources/vendor
cp node_modules/marked/lib/marked.umd.js Resources/vendor/marked.js
cp node_modules/dompurify/dist/purify.min.js Resources/vendor/purify.min.js
cp node_modules/mermaid/dist/mermaid.min.js Resources/vendor/mermaid.min.js
chmod +x Scripts/build.sh
Scripts/build.sh --install
```

The installed app lives at `/Applications/Satr.app`. Its bundle identifier is `sa.hatim.Satr`, and its document declaration gives Finder an **Open With > Satr** option for Markdown files.
