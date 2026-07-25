# Satr

Satr is Hatim's local macOS Markdown reader. It opens `.md`, `.markdown`, `.mdown`, and `.mkd` files, renders GitHub-flavored Markdown and Mermaid diagrams, follows local links, resolves Obsidian-style wiki links, and reloads when the source file changes.

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
