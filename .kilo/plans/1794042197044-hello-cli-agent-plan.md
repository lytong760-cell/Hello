# Hello CLI — Implementation Plan

## Goal
Build `hello`, a single-binary Zig agent CLI mirroring Claude Code / Opencode / Kilo / Pi / Codex UX: interactive REPL, file + shell tools, multi-provider LLM, sessions, slash commands, skills.

## Stack
- Language: Zig (match repo skeleton). Target Zig 0.13+.
- UI: ANSI + readline-style line editor (no external TUI lib).
- HTTP/JSON: std.http + manual JSON (or vendored tiny JSON parser).
- Storage: ALWAYS both global (XDG: `~/.config/hello`, `~/.local/share/hello`, `~/.local/state/hello`) and project-local (`.hello/`). Project-local overrides global on name conflicts; both are scanned/merged at load time.

## v1 Feature Set
- Interactive REPL with streaming LLM responses
- Tools: `read`, `write`, `edit`, `grep`, `glob`, `bash` (prompt-per-call permission)
- Providers: OpenAI, Anthropic, Google, Kilo Gateway (OpenAI-compatible base URLs)
- Sessions: persist/resume conversations (JSON on disk)
- Slash commands: `/help`, `/clear`, `/model`, `/session`, `/skills`, `/exit`
- Skills: loadable markdown skill files from global + project dirs
- Single general agent (no plan/code/debug modes in v1)

## Architecture
```
src/
  main.zig          # entry, arg parsing
  config.zig        # load config (global + project merge)
  repl.zig          # input loop, slash command dispatch
  llm/
    provider.zig    # provider interface
    openai.zig
    anthropic.zig
    google.zig
    kilo.zig        # OpenAI-compatible
  tools/
    read.zig write.zig edit.zig grep.zig glob.zig bash.zig
    registry.zig
  session.zig       # persist/resume
  skills.zig        # load markdown skills
  permissions.zig   # prompt per call
  ui.zig            # ANSI streaming output
```

## Storage Layout (global + local, always both)
- Global: `~/.config/hello/` (config.json, skills/), `~/.local/share/hello/` (sessions/), `~/.local/state/hello/` (logs, history).
- Project: `.hello/` at cwd (config.json, skills/, sessions/).
- Merge: load global first, then project-local; project wins on conflict. New artifacts written to project-local if `.hello/` exists else global.

## Data Flow1. Load config (API keys from env/config).
2. Start REPL; read user input.
3. Build messages (system + skills + history + user).
4. Stream LLM response; on tool_call, run tool (with permission prompt), append result, re-call LLM.
5. Persist session after each turn.

## Key Decisions
- Zig std only + vendored JSON parser to avoid dependency hell.
- Providers normalized to a common `chat(messages, tools) -> stream` interface.
- Tool results capped (e.g. 30k chars) to protect context.
- Sessions stored as JSONL for append-friendly resume.
- Skills: frontmatter (name/description) + body injected into system prompt when invoked.

## Failure Modes
- Missing API key -> clear error + hint.
- Tool failure -> return error text to model, don't crash.
- Network timeout -> retry with backoff (3 attempts).
- Large file read -> truncate with notice.

## Validation
- `zig build` succeeds.
- `zig build test` passes unit tests for tools + JSON parsing.
- Manual smoke: `hello` starts REPL; `/help` lists commands; a tool-using turn completes end-to-end against one provider.

## Out of Scope (v1)
- MCP servers, subagents, agent modes, TUI panels, plugins, hooks.
- Windows support (Linux/macOS first).

## Open Questions
- Resolved: config format JSON.
- Deferred to implementation: SSE parsing per provider (OpenAI/Anthropic/Google differ).
- v1 ships source-only; prebuilt binaries later.

## v1 Status
- Implemented and building: config, providers (OpenAI/Anthropic/Google/Kilo), tools, REPL, sessions, skills, slash commands.
- Remaining gaps below are v1.1.

## v1.1 Polish (next)
- README + install instructions (build from source, env vars).
- Unit tests: JSON parsing, read/write/edit/glob/grep/bash, config merge, session round-trip.
- Streaming responses: parse SSE per provider; print tokens as they arrive; tool calls assembled incrementally.
- Tool-calling for Anthropic and Google (currently text-only).
- One-shot mode: `hello "prompt"` runs single turn, prints, exits.
- Memory cleanup: avoid page_allocator leaks reporting; free owned strings or use arena per turn.
- Error UX: retry with backoff on network errors; clearer missing-key hints.
- Context protection: cap tool results at 30k chars; truncate large reads with notice.
- Session IDs: auto-generate if not provided; list/resume by id (`/session list`).

## v1.1 Validation
- `zig build test` passes new tests.
- Manual: streaming turn prints incrementally; tool-using turn works against Kilo gateway when credits available.
- One-shot: `hello "echo hi"` prints response and exits 0.
## Task List (v1 - done)
1-10. (completed)

## Task List (v1.1 - next)
1. Add README with build/run/env docs.
2. Add tests in src/*_test.zig and wire into build.zig test step.
3. Implement SSE streaming in llm/provider.zig for OpenAI; refactor chat to stream callback.
4. Extend streaming to Anthropic and Google; unify tool-call deltas.
5. Implement tool-calling for Anthropic and Google request/response.
6. Add one-shot mode in main.zig.
7. Memory cleanup pass (arena per turn).
8. Retry/backoff for HTTP errors.
9. Tool result truncation.
10. Session list/resume commands.
