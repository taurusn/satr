# Linen's MCP server: research

Read 2026-10-15. Every quote below was taken from a raw page saved in `docs/research/raw/mcp/` (local only) and checked by text search; the file name and date are in the numbered sources at the end of each section. Anything not confirmed that way is marked **unconfirmed**.

## Two-minute read

| Question | Answer |
|---|---|
| Which MCP version | **2026-07-28** is current [1]. It removed the `initialize` handshake: every request carries its version in `_meta`, and servers must answer `server/discover` [2]. Most installed clients still speak **2025-11-25** with `initialize`; Claude Code asks stdio servers for the new revision and falls back [14]. So `linen mcp` must be **dual-era**: answer `initialize` and `server/discover`, and serve per-request `_meta` [3]. |
| What servers can return | Text, image, audio, resource links and embedded resources in `content`; any JSON value in `structuredContent`, which "SHOULD also" appear as serialized JSON in a text block; `isError: true` for errors the model can fix; protocol errors only for bad requests and unknown tools [4]. Tool `annotations`: `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`, all hints [5]. |
| Rules that matter most | Few tools built around whole workflows, not one per endpoint; descriptions written like a brief for a new hire, at least 3 to 4 sentences; return names and titles, not ids alone; concise by default with a `response_format` switch; truncate with guidance; errors that say what to do next; measure with real agent runs [11] [13]. |
| Claude Code limits | Warns over 10,000 tokens of tool output, caps at 25,000 (`MAX_MCP_OUTPUT_TOKENS`), saves text over 50,000 characters to a file; images reach Claude inline; descriptions and server instructions are cut at 4,096 characters when loaded upfront; tool names are `mcp__<server>__<tool>`; stdio tool calls idle out after 30 minutes and move to the background after 2 minutes [14]. |
| Codex limits | `startup_timeout_sec` 10 and `tool_timeout_sec` 60 by default; `writes` approval mode prompts for tools not marked read-only; keep the first 512 characters of server instructions self-contained [17]. **When a result has `structuredContent`, Codex sends only that JSON to the model and drops the `content` blocks, images included** [18]. |
| Swift SDK or own server | Write our own small JSON-RPC stdio server in `Tools/linen/`. The official Swift SDK (0.12.1, May 2026) implements 2025-11-25, not 2026-07-28, and pulls in swift-nio, swift-log, swift-system, an EventSource package and the DocC plugin from a branch [22]. |
| How to test | MCP Inspector's CLI in both eras (`--protocol-era legacy|modern`) for the protocol [23]; `claude -p --strict-mcp-config --mcp-config` and `codex exec -c mcp_servers.linen...` for real agent runs, scored on realistic tasks with transcripts read [11] [15] [20]. |

## 1. The specification (2026-07-28)

**Version and negotiation.** The versioning page says: "The current protocol version is 2026-07-28." [1] The key changes page lists, as major change 2: "Make MCP stateless: remove the initialize/notifications/initialized handshake. Every request now carries its protocol version and client capabilities in _meta (io.modelcontextprotocol/protocolVersion, io.modelcontextprotocol/clientCapabilities)." and change 3: "Add server/discover: servers MUST implement this RPC to advertise their supported protocol versions, capabilities, and identity." [2] An unsupported version gets error `-32022` with the supported list in `data.supported` [3].

**Dual era.** The spec defines "Legacy: protocol versions that establish a session with an initialize handshake (2025-11-25 and earlier)" and allows a server to serve both: "A request carrying modern per-request _meta is served statelessly according to this revision" and "An initialize request selects legacy semantics, scoped to the stdio process" [3]. On stdio a dual-era client probes with `server/discover` and falls back to `initialize` on "any other error, or does not respond within a reasonable timeout" [6]. In the legacy handshake, "If the server supports the requested protocol version, it MUST respond with the same version. Otherwise, the server MUST respond with another protocol version it supports." [8]

**stdio rules.** "Messages are delimited by newlines, and MUST NOT contain embedded newlines." "The server MUST NOT write anything to its stdout that is not a valid MCP message." "The server MAY write UTF-8 strings to stderr for any logging purposes." "Servers SHOULD exit promptly when their standard input is closed or reads return end-of-file." [6] The MCP build guide repeats it for every language: "Never write to stdout. Writing to stdout will corrupt the JSON-RPC messages and break your server." [10] (Linen's existing command prints its results with `print`, so `linen mcp` must route every byte through one JSON writer.)

**Tools.** A tool has `name`, optional `title`, `description`, `inputSchema` (JSON Schema, 2020-12 by default), optional `outputSchema`, `annotations`, `icons` [4]. Names "SHOULD be between 1 and 128 characters" using letters, digits, `_`, `-` and `.` [4]. In 2026-07-28 servers "SHOULD return tools in a deterministic order", and list results must carry `ttlMs` and `cacheScope` [2]. Every result carries `resultType` (`"complete"` for ordinary results) [2]. There is no `input_examples` field in MCP tools (it is a Claude API field [13]), so examples belong in the description.

**Results.** Image content is `{"type": "image", "data": "base64-encoded-data", "mimeType": "image/png"}`, optionally with `annotations.audience` and `priority` [4]. A tool "MAY return links to Resources" (`resource_link`) and may embed resources [4]. "For backwards compatibility, a tool that returns structured content SHOULD also return the serialized JSON in a TextContent block." If an `outputSchema` is given, "Servers MUST provide structured results that conform to this schema." [4]

**Errors.** "Protocol Errors indicate issues with the request structure itself that models are less likely to be able to fix: Unknown tool, Malformed requests ..., Server errors." "Tool Execution Errors contain actionable feedback that language models can use to self-correct and retry with adjusted parameters" and are "reported in tool results with isError: true". "Clients SHOULD provide tool execution errors to language models to enable self-correction." [4]

**Annotations** (all hints, "not guaranteed to provide a faithful description"): `readOnlyHint` "If true, the tool does not modify its environment. Default: false"; `destructiveHint` "If true, the tool may perform destructive updates ... If false, the tool performs only additive updates" (default true); `idempotentHint` "calling the tool repeatedly with the same arguments will have no additional effect" (default false); `openWorldHint` "may interact with an open world of external entities" (default true) [5]. Clients must treat them as untrusted unless the server is trusted [4].

**State.** "MCP has no protocol-level session, so a server cannot rely on implicit per-connection state", so state across calls uses explicit handles passed as arguments, and "A call against an expired or unknown handle should return a tool execution error that says so" [4]. Linen needs none: a file path is the handle.

**Progress, cancellation, logging.** `progressToken` in `_meta` asks for `notifications/progress`; "The receiver is not obligated to provide these notifications." [5] On stdio, cancellation is `notifications/cancelled`; servers "SHOULD stop work on a cancelled request as soon as practical and MUST NOT send any further messages for it" [6]. 2026-07-28 deprecates Roots, Sampling and Logging; the migration is to "pass directories or files via tool parameters" and "log to stderr (stdio)" [2]. It also notes an MCP Apps extension, `io.modelcontextprotocol/ui` with `text/html;profile=mcp-app` [3]; not needed here.

Sources
1. https://modelcontextprotocol.io/specification/versioning (`spec-versioning-2026-10-15.html`, `.txt`), read 2026-10-15.
2. https://modelcontextprotocol.io/specification/2026-07-28/changelog (`spec-2026-07-28-changelog-2026-10-15.*`), read 2026-10-15.
3. https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning (`spec-2026-07-28-basic-versioning-2026-10-15.*`), read 2026-10-15.
4. https://modelcontextprotocol.io/specification/2026-07-28/server/tools (`spec-2026-07-28-tools-2026-10-15.*`), read 2026-10-15.
5. https://modelcontextprotocol.io/specification/2026-07-28/schema (`spec-2026-07-28-schema-2026-10-15.*`), ToolAnnotations and ProgressToken, read 2026-10-15.
6. https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio (`spec-2026-07-28-stdio-2026-10-15.*`), read 2026-10-15.
7. https://modelcontextprotocol.io/specification/2026-07-28/server/discover (`spec-2026-07-28-discover-2026-10-15.*`), read 2026-10-15.
8. https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle (`spec-2025-11-25-lifecycle-2026-10-15.*`), read 2026-10-15.
9. https://modelcontextprotocol.io/specification/2025-11-25/server/tools (`spec-2025-11-25-tools-2026-10-15.*`), read 2026-10-15.
10. https://modelcontextprotocol.io/docs/develop/build-server, served as `/docs/2026-07-28/develop/build-server` (`mcp-docs-build-server-2026-10-15.*`), read 2026-10-15.

## 2. Tool design for agents

From Anthropic's engineering post "Writing effective tools for agents" (its full title adds "with agents"; published Sep 11, 2025) [11]:

- **Fewer, workflow-shaped tools.** "More tools don't always lead to better outcomes. A common error we've observed is tools that merely wrap existing software functionality or API endpoints." "Tools can consolidate functionality, handling potentially multiple discrete operations (or API calls) under the hood." Examples: `search_logs` instead of `read_logs`, `get_customer_context` instead of three getters. "Too many tools or overlapping tools can also distract agents."
- **Search, don't list.** An agent reading every contact "is wasting its limited context space"; implement `search_contacts` rather than `list_contacts`.
- **Namespacing.** "namespacing tools by service ... and by resource ... can help agents select the right tools at the right time", and prefix or suffix choice has "non-trivial effects", so decide by evaluation.
- **Meaningful context.** Return "only high signal information", avoid "low-level technical identifiers (for example: uuid, 256px_image_url, mime_type)"; resolving UUIDs to meaningful names "significantly improves Claude's precision in retrieval tasks by reducing hallucinations".
- **Concise or detailed.** "exposing a simple response_format enum parameter in your tool, allowing your agent to control whether tools return 'concise' or 'detailed' responses"; their Slack example used about a third of the tokens concise.
- **Token budget.** "implementing some combination of pagination, range selection, filtering, and/or truncation with sensible default parameter values"; "For Claude Code, we restrict tool responses to 25,000 tokens by default."; "If you choose to truncate responses, be sure to steer agents with helpful instructions."
- **Errors as prompts.** "prompt-engineer your error responses to clearly communicate specific and actionable improvements, rather than opaque error codes or tracebacks."
- **Descriptions.** "think of how you would describe your tool to a new hire on your team"; "input parameters should be unambiguously named: instead of a parameter named user, try a parameter named user_id"; "Even small refinements to tool descriptions can yield dramatic improvements."
- **Evaluate with agents.** Strong tasks "might require multiple tool calls" (the post says potentially dozens); collect "the total runtime of individual tool calls and tasks, the total number of tool calls, the total token consumption, and tool errors"; "Review the raw transcripts"; use "held-out test sets".

From Claude's tool-use docs ("Define tools") [13]: descriptions are "by far the most important factor in tool performance" and should cover what the tool does, "When it should be used (and when it shouldn't)", what each parameter means, and caveats; "Aim for at least 3–4 sentences for each tool description"; "Consolidate related operations into fewer tools ... group them into a single tool with an action parameter"; return "semantic, stable identifiers".

From "Code execution with MCP" (published Nov 04, 2025) [12]: "Every intermediate result must pass through the model" and "models may be more likely to make mistakes when copying data between tool calls." For Linen this means tools take **file paths**, never the board's JSON as an argument: the agent writes the file with its own editor tools, and Linen's tools read it.

From Codex's MCP page [17]: "use instructions for cross-tool workflows, constraints, and rate limits that apply across the server. Keep the first 512 characters self-contained." No other published OpenAI guidance on tool design was found in the saved pages (**unconfirmed** whether more exists).

Sources
11. https://www.anthropic.com/engineering/writing-tools-for-agents (`anthropic-writing-tools-for-agents-2026-10-15.*`), read 2026-10-15.
12. https://www.anthropic.com/engineering/code-execution-with-mcp (`anthropic-code-execution-with-mcp-2026-10-15.*`), read 2026-10-15.
13. https://docs.claude.com/en/docs/agents-and-tools/tool-use/implement-tool-use, served as https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools (`claude-docs-implement-tool-use-2026-10-15.*`), read 2026-10-15.

## 3. What the clients do

**Claude Code** [14] [15] [16]
- Output: "displays a warning when MCP tool output exceeds 10,000 tokens and limits output to 25,000 tokens by default"; over the limit a text result is saved to a file and replaced by its path; "successful text results longer than 50,000 characters are saved to a file regardless". A tool can raise its own text threshold with `_meta["anthropic/maxResultSizeChars"]` up to 500,000 characters. Error text over about 11,000 characters keeps its first and last 5,000.
- Images: "When an MCP tool returns a PNG, JPEG, GIF, or WebP image, Claude sees the image inline in the conversation. The inline copy may be scaled down or compressed", and Claude Code also saves the original bytes and gives Claude the path. Image results stay subject to `MAX_MCP_OUTPUT_TOKENS`.
- Descriptions: "Server instructions, and the description of a tool that loads upfront: 4,096 characters"; a deferred tool's description: 16,384; "put critical details near the start". With tool search on, "Only tool names and server instructions load at session start", so server instructions should say what tasks the tools handle and when to search for them. `_meta["anthropic/alwaysLoad"]: true` asks for a tool to load upfront.
- Schemas: root-level `anyOf`/`oneOf`/`allOf` get flattened; property names must be 1 to 64 characters of letters, digits, `_`, `.` and `-`; the schema must validate against 2020-12.
- Names and permissions: plugin tools are `mcp__plugin_<plugin>_<server>__<tool>`; configured servers give `mcp__<server>__<tool>`; allow rules accept `mcp__linen__*` [16]. Full names over 128 characters are dropped.
- Timeouts: `MCP_TIMEOUT` for startup; a per-server `timeout` or `MCP_TOOL_TIMEOUT` for calls; stdio calls abort after 30 minutes with no response or progress; a call running past two minutes moves to a background task.
- Protocol: Claude Code's v2 runtime "Asks HTTP, stdio, and claude.ai connector servers whether they support the newer revision, and uses it with those that do. It connects to every other server as v1 does." `MCP_PROTOCOL_NEGOTIATION=legacy` forces the old handshake.
- Commands: `claude mcp add [options] <name> -- <command> [args...]`, scopes `local` (default), `project`, `user`; `--mcp-config` with `-p` waits for servers to connect up to `MCP_TIMEOUT` (30 s default); `--strict-mcp-config` uses only those servers [15].
- **Unconfirmed:** whether Claude Code shows the model `structuredContent`, `content`, or both. The docs read do not say.

**Codex CLI** (codex-cli 0.160.0 on this Mac) [17] [18] [19] [20]
- Config: `[mcp_servers.<name>]` with `command`, `args`, `env`, `cwd`; `startup_timeout_sec` (default 10), `tool_timeout_sec` (default 60), `enabled_tools`, `disabled_tools`, `default_tools_approval_mode` (`auto`, `prompt`, `writes`, `approve`; "The writes mode prompts for tools that aren't marked read-only"), per-tool `output_token_limit`. `codex mcp add <NAME> -- <COMMAND>...`; `codex exec -c key=value` overrides any config value.
- Server instructions: "Codex reads the MCP instructions field returned during initialization and uses it as server-wide guidance".
- **Structured content wins.** In `codex-rs/protocol/src/models.rs` (main, read 2026-10-15, `as_function_call_output_payload`, line 2436 of the saved file), when `structured_content` is present and not null the function returns `FunctionCallOutputBody::Text(serialized_structured_content)`; only without it does it convert `content`, where `"image"` becomes an `InputImage` data URL and unknown types such as `resource_link` become their JSON as text [18]. So: a tool whose answer is an image must not set `structuredContent`, and any tool that sets it must put everything the model needs inside it.

**Cursor** [21]: "MCP servers can return images ... Cursor attaches returned images to the chat. If the model supports images, it analyzes them."

Sources
14. https://code.claude.com/docs/en/mcp (`claude-code-mcp-docs-2026-10-15.*`), read 2026-10-15.
15. https://code.claude.com/docs/en/cli-reference (`claude-code-cli-reference-2026-10-15.*`), read 2026-10-15.
16. https://code.claude.com/docs/en/permissions (`claude-code-permissions-docs-2026-10-15.*`), read 2026-10-15.
17. https://developers.openai.com/codex/mcp, served as https://learn.chatgpt.com/docs/extend/mcp?surface=cli (`codex-mcp-docs-2026-10-15.*`), read 2026-10-15.
18. https://raw.githubusercontent.com/openai/codex/main/codex-rs/protocol/src/models.rs (`codex-rs-protocol-models-2026-10-15.rs`), read 2026-10-15.
19. https://raw.githubusercontent.com/openai/codex/main/codex-rs/tools/src/tool_output.rs (`codex-rs-tool_output-2026-10-15.rs`), read 2026-10-15.
20. Local `codex exec --help`, `codex mcp add --help`, `codex --version` (`codex-exec-help-2026-10-15.txt`, `codex-mcp-add-help-2026-10-15.txt`), 2026-10-15.
21. https://cursor.com/docs/context/mcp, served as https://cursor.com/docs/mcp (`cursor-mcp-docs-2026-10-15.*`), read 2026-10-15.

## 4. Swift: SDK or our own

The official SDK (`modelcontextprotocol/swift-sdk`) "implements both client and server components according to the 2025-11-25 (latest) version" of the spec [22]. Its latest release is 0.12.1 (2026-05-07; 0.12.0 March, 0.11.0 February) and it is pre-1.0. It needs Swift 6.0+, macOS 13+, and "is licensed under Apache 2.0 for new contributions, with existing code under MIT". Its `Package.swift` (tools version 6.1) depends on swift-system, swift-log, mattt/eventsource, swift-nio and swift-docc-plugin pinned to `branch: "main"`. It has a `StdioTransport`.

**Recommendation: write our own** stdio server inside `Tools/linen/` (one or two files). Reasons: the SDK does not speak 2026-07-28 or `server/discover` yet, which we need anyway for Claude Code's v2 runtime; it would bring five packages, one from a moving branch, into a project that has none; our surface is small (legacy `initialize` and `notifications/initialized`, `server/discover`, `ping` for legacy clients, `tools/list`, `tools/call`, `resources/list` and `resources/read` for the guide, `notifications/cancelled`), and JSON-RPC over newline-delimited stdio is a few hundred lines with Foundation's `JSONSerialization`. The cost is following future spec revisions by hand; the Inspector's two era modes catch drift.

Sources
22. https://raw.githubusercontent.com/modelcontextprotocol/swift-sdk/main/README.md, `Package.swift`, and the GitHub API for releases and repo (`swift-sdk-readme-2026-10-15.md`, `swift-sdk-Package-2026-10-15.swift`, `swift-sdk-releases-2026-10-15.json`, `swift-sdk-repo-2026-10-15.json`), read 2026-10-15.

## 5. Testing tools

- **MCP Inspector CLI** (v2 line) [23]: `npx @modelcontextprotocol/inspector --cli <command> [args] --method tools/list`; calls with `--method tools/call --tool-name <name> --tool-arg key=value` or `--tool-args-json '<json>'`; `--method initialize` is a "connect-only probe"; `--protocol-era` takes `legacy`, `auto` or `modern`. Requires Node 22.19 or later.
- **Claude Code headless** [15]: `claude -p "<task>" --strict-mcp-config --mcp-config <file.json> --allowedTools "mcp__linen__*" ... --output-format stream-json --verbose`.
- **Codex** [20]: `codex exec --json -c 'mcp_servers.linen.command="..."' -c 'mcp_servers.linen.args=["mcp"]' "<task>"`.

Sources
23. https://raw.githubusercontent.com/modelcontextprotocol/inspector/main/README.md and `clients/cli/README.md` (`inspector-readme-2026-10-15.md`, `inspector-cli-readme-2026-10-15.md`), read 2026-10-15.

## What this means for Linen's MCP

`linen mcp` runs Linen's own renderer, as the other subcommands do, over stdio. The agent writes files with its own editor tools; Linen's tools read them by path, check and draw them, and show them to Hatim.

### Server instructions (first 512 characters stand alone)

> Linen is the reader Hatim uses for what agents make: notes (Markdown with Loom blocks), boards (JSON Canvas `.canvas`) and sealed pages (`.html`). Write the file with your own tools, then: check_file, layout_board for boards, preview_file at 1176 and 390 px, fix every problem, then open_in_linen. Pass absolute paths. Never inline fonts or colours; Linen draws them. Call format_guide before writing a board or blocks for the first time. get_reader_state tells you what Hatim has open or selected.

The rest (up to about 2,000 characters, well under 4,096): the six default status words and shapes, the four JSON Canvas types, ids as stable names, sidecar notes, the phone width check.

### Tools

Deterministic order; names without a `linen_` prefix because both clients already add the server name (`mcp__linen__check_file`), to be confirmed by the evaluation as [11] advises. Every description: what it does, when to use it and when not, each parameter, caveats, one example call, with the key words in the first sentence (tool search reads the start).

| Tool | Purpose | Inputs | Output | Annotations |
|---|---|---|---|---|
| `check_file` | Validate notes, boards and pages exactly as Linen will draw them | `paths`: 1 to 20 absolute paths; `response_format`: `concise` (default) or `detailed` | Per file: kind, error and warning counts, problems with line, JSON path, message and a fix sentence; concise caps 20 problems per file with "N more" | readOnly, idempotent, closed world |
| `preview_file` | See a file the way Hatim will, from Linen's real renderer | `path`; `width` 390, 1176 (default) or 1440; `theme` paper or night; `view` fit, a node id or a section name (boards); `full_page` (notes, pages) | One PNG plus one text line: problem count, what is in view (zoom level, section), where the PNG was saved | readOnly (writes only into Linen's cache), idempotent, closed world |
| `layout_board` | Size every card to its text with Linen's fonts and place sections that ask for layout | `path`; `dry_run` (default false) | Nodes moved, sections grown, cards that still overflow (id and title), whether the file was normalised once, time | not readOnly, destructive false (changes positions and sizes only, never content), idempotent, closed world |
| `read_board` | Read a board as an outline instead of raw JSON | `path`; optional `section`, `word`, `query`; `include_notes`; `offset`, `limit` (default 50); `response_format` | Title, words with counts, sections with rows (id, title, word, first body line, connections by title), problem count, `next_offset` | readOnly, idempotent, closed world |
| `open_in_linen` | Show Hatim a file without taking him out of what he is doing | `path`; optional `node` or `line`; `focus` (default false) | Which tab it opened in and whether Linen took focus | not readOnly, destructive false, idempotent, closed world |
| `get_reader_state` | What Hatim has open and selected in Linen now | `include_text` (default true) | Front file (path, kind, title), other open tabs, the selected box (id, title, text, its sidecar note key) or the selected note text with its line range, the section in view and zoom level, unseen changes count | readOnly, idempotent, closed world |
| `get_unseen_changes` | What changed in a file since Hatim last looked at it | `path` | Since when, then added, changed and removed boxes (or note blocks) with titles and line ranges, or "rewritten since you read it" | readOnly, idempotent, closed world |
| `format_guide` | The rules for writing boards, notes with blocks and pages | `topic`: `boards`, `notes`, `pages`, `loop` or `all` | The matching section of `docs/FORMAT.md`; also served as resource `linen://guide/format` | readOnly, idempotent, closed world |

`get_reader_state` and `get_unseen_changes` need the app to share its state with the command (a small state file Linen writes, or XPC); they are the tools that let an agent act on "this box" when Hatim points at one.

### Response shapes

- Text tools return `structuredContent` (an object whose first key is a one-sentence `summary`) and the same JSON as one text block, as the spec asks [4]. Because Codex sends the model only `structuredContent` [18], it must be complete on its own: summary, counts, problems with fixes, next step.
- `preview_file` returns the image and a text line, and **no** `structuredContent`, so the image reaches Codex's model [18]. Viewport screenshots at 1x by default (1176 by 900, 390 by 844); `full_page` caps height at 4,000 px and says so when it cut.
- Names and titles beside every id ("n-approve, Approval flow"), never ids alone [11].
- Every result names the absolute path it acted on, so a wrong relative path shows at once.

### Errors

- Protocol errors only for an unknown tool or arguments that do not match the schema (`-32602`); everything else is `isError: true` with two or three sentences: what was wrong, what to do, an example. For example: "layout_board takes a board (.canvas). /x/report.md is a note; use check_file for notes." Or: "No file at map.canvas. Pass an absolute path, for example /Users/you/project/map.canvas."
- A file with problems is not an error: `check_file` succeeds and lists them; `isError` is for calls that could not do their job.
- Error text stays under 2,000 characters (Claude Code keeps only the ends of long error text [14]).

### Limits

- Text results stay under about 8,000 tokens by default (below Claude Code's 10,000 token warning [14]) through concise output, caps and `offset`; nothing relies on the 50,000 character persist-to-disk fallback.
- One image per call; agents ask for a second width with a second call.
- Every call finishes inside 30 seconds (Codex's default tool timeout is 60 [17]); the renderer starts lazily on the first preview or layout, so the server answers `initialize` and `server/discover` in milliseconds (Codex waits 10 seconds for startup [17]).
- `notifications/cancelled` stops a render; stdin closing ends the process [6].
- Nothing is written to stdout but JSON-RPC lines; logs go to stderr [6] [10].

### Protocol

Dual era [3]: answer `initialize` with the client's version when it is 2025-11-25, 2025-06-18 or 2025-03-26, else 2025-11-25, and accept `notifications/initialized` and `ping`; answer `server/discover` with `supportedVersions` `["2026-07-28", "2025-11-25"]`, capabilities `tools` and `resources`, `serverInfo` in `_meta` and the instructions; on requests carrying `_meta["io.modelcontextprotocol/protocolVersion"]` check it (`-32022` with the supported list otherwise) and add `resultType: "complete"` to results, plus `ttlMs` and `cacheScope: "private"` on `tools/list`, `resources/list` and `resources/read` [2].

### Test plan

1. **Protocol, both eras:**
   ```sh
   npx @modelcontextprotocol/inspector --cli --protocol-era legacy /Applications/Linen.app/Contents/Helpers/linen mcp --method tools/list
   npx @modelcontextprotocol/inspector --cli --protocol-era modern /Applications/Linen.app/Contents/Helpers/linen mcp --method tools/list
   npx @modelcontextprotocol/inspector --cli /Applications/Linen.app/Contents/Helpers/linen mcp --method tools/call --tool-name check_file --tool-args-json '{"paths":["/abs/path/map.canvas"]}'
   ```
   Plus a scripted stdio test (JSON lines in, lines out): `initialize`, `server/discover`, an unsupported version (`-32022`), an unknown tool (`-32602`), bad arguments (`isError`), cancellation, stdin EOF, and a check that every stdout line parses as JSON.
2. **Registration:** `claude mcp add --transport stdio --scope user linen -- /Applications/Linen.app/Contents/Helpers/linen mcp` and `codex mcp add linen -- /Applications/Linen.app/Contents/Helpers/linen mcp`.
3. **Agent evaluation** [11]: about ten realistic multi-step tasks, each with a checkable outcome, for example: build a readiness board for a sample repository from its code and tests, check it, preview it at 390 px in Night, fix every problem and open it at its Broken boxes; explain and fix the box Hatim has selected; summarise what changed on a board since Hatim last looked; turn a long note into a note with tiles and steps that passes `check_file`. Run each three times in Claude Code (`claude -p "<task>" --strict-mcp-config --mcp-config linen-mcp.json --allowedTools "mcp__linen__*" Read Write Edit --output-format stream-json --verbose`) and in Codex (`codex exec --json -c 'mcp_servers.linen.command="/Applications/Linen.app/Contents/Helpers/linen"' -c 'mcp_servers.linen.args=["mcp"]' "<task>"`), on fixtures outside the public repo. Score success, tool calls, tool errors, tokens and time; read the transcripts for wrong tools, bad arguments and repeated calls; change descriptions and responses; rerun on held-out tasks.

### Top rules

1. Few tools shaped like the agent's loop (check, preview, layout, open, read state), not one per command flag.
2. Paths in, never file contents: the agent edits with its own tools.
3. Descriptions are prompts: what, when, when not, parameters, caveats, one example, key words first, under about 1,500 characters each.
4. Concise by default, `response_format` for detail, caps with "N more" and how to get them.
5. Names and titles next to every id.
6. `isError` with a next step; a file with problems is a successful check.
7. Images without `structuredContent`; structured results complete on their own.
8. Dual-era protocol, stdout only for JSON-RPC, every call under 30 seconds, then measure with real Claude Code and Codex runs.
