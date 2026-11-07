# Hello CLI

A single-binary agent CLI written in Zig, inspired by Claude Code, Opencode, Kilo, Pi, and Codex.

## Build

Requires Zig 0.13+.

```
zig build -Doptimize=ReleaseFast
# binary at zig-out/bin/hello
```

## Run

```
hello                       # interactive REPL
hello --provider kilo       # choose provider
hello --model gpt-4o-mini   # choose model
hello --session mysession   # resume named session
```

## Configuration

Config is JSON, loaded from (in order, later overrides):
- `~/.config/hello/config.json` (global)
- `./.hello/config.json` (project-local)

Example:
```json
{
  "provider": "openai",
  "model": "gpt-4o-mini",
  "api_keys": {
    "openai": "sk-...",
    "anthropic": "sk-ant-...",
    "google": "...",
    "kilo": "..."
  },
  "base_url": "https://api.openai.com/v1"
}
```

Environment variables override config keys: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, `KILO_API_KEY`.

## Skills

Markdown files in `~/.config/hello/skills/` or `./.hello/skills/` with optional frontmatter:
```markdown
---
name: my-skill
description: does a thing
---
Body injected into system prompt.
```

## Slash Commands

`/help /clear /model <name> /provider <name> /session <name> /skills /exit`

## Tools

`read, write, edit, grep, glob, bash`. Dangerous tools (write/edit/bash) prompt for confirmation.
