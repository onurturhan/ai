# README

## Purpose

This repository provides a bootstrap script to launch a multi-AI CLI tmux workspace running Claude, Gemini, and Codex side-by-side in a single terminal session.

## Usage

The script **must be sourced**, not executed directly, because it sets environment variables and aliases in the calling shell:

```bash
source setup_ai.sh
```

After setup, reattach to the workspace at any time with:

```bash
aia           # alias added to ~/.bashrc
# or
tmux attach -t ai
```

## Prerequisites

- Node.js and npm must be installed before sourcing the script.
- API keys should be set in the environment before sourcing so they are persisted to `~/.ai_env`:
  - `ANTHROPIC_API_KEY`
  - `OPENAI_API_KEY`
  - Gemini uses `gcloud` auth or `GEMINI_API_KEY` depending on the CLI version.
- If the required API keys are not set, the CLI tools may prompt for authentication through a browser-based login flow when first executed.

## Architecture

### `setup_ai.sh`

Single idempotent setup script that:
1. Configures npm global prefix to `~/.npm-global` (avoids sudo).
2. Installs `@anthropic-ai/claude-code`, `@google/gemini-cli`, and `@openai/codex` globally if missing.
3. Persists API keys to `~/.ai_env` (mode 600) and sources it into the current shell.
4. Installs and configures tmux if missing.
5. Creates a tmux session named `ai` with a tiled 4-pane layout:
   - Pane 0 (Claude): `claude --settings .ai/claude.json`
   - Pane 1 (Gemini): `gemini --output-format text`
   - Pane 2 (Codex): `codex --no-alt-screen`
   - Pane 3 (Shell): free shell
6. Binds `Ctrl+b 1-4` to jump between panes.

### `.ai/` — Per-tool configuration

| File | Tool | Key settings |
|------|------|--------------|
| `claude.json` | Claude Code | `permissionMode: "default"`, tools: default |
| `gemini.json` | Gemini CLI | `approval-mode: "default"`, `output-format: "text"` |
| `codex.toml` | OpenAI Codex | model: `o4-mini`, `sandbox_permissions: ["workspace-write"]`, inherits full shell env |

### State files created outside the repo

| Path | Purpose |
|------|---------|
| `~/.ai_env` | Persisted API key exports (chmod 600) |
| `~/.npm-global` | npm global prefix (avoids sudo) |
| `~/ai-setup.log` | Full setup log (stdout+stderr) |

### Repo management
```bash
  git checkout main
  git reset $(git commit-tree HEAD^{tree} -m "Initial commit")
  git push -f origin main
```
```bash
  rm -rf .git
  git init -b main        # ensures branch is main
  git add .
  git commit -m "Initial commit"
  git remote add origin https://github.com/onurturhan/ai.git
  git push -f -u origin main
```