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

## Task List (ordered)
1. Scaffold `build.zig` + src layout.
2. Config loader (JSON, env override, global+project merge).
3. Provider interface + OpenAI implementation + streaming.
4. Add Anthropic, Google, Kilo providers.
5. Tool registry + read/write/edit/grep/glob/bash with permission prompts.
6. REPL loop + slash commands.
7. Session persistence/resume.
8. Skills loader.
9. Tests + smoke run.
10. README + install instructions.
