# Offline Mode

Run Claude Code autonomously on the VCC while your laptop is closed.

## Quick Start

```bash
# Run a task autonomously
claude-offline "fix the failing tests in the auth module"

# With options
claude-offline --project ~/Life-Dashboard --budget 10 --timeout 3600 "refactor the API layer"

# Check status
claude-offline --status

# View live output
claude-offline --logs

# See task history
claude-offline --history

# See structured result
claude-offline --result
```

## How It Works

1. Creates a detached tmux session (`offline-<timestamp>`)
2. Runs `claude -p --output-format json --permission-mode bypassPermissions` with your prompt
3. On failure: retries with exponential backoff, resuming the Claude session
4. Logs human-readable output to `.log` and structured data to `.jsonl`
5. Sends push notifications via ntfy.sh on completion/failure (if configured)

## Configuration

Edit `~/.config/claude-offline/config.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `CO_MAX_RETRIES` | 3 | Retry attempts on transient failures |
| `CO_BACKOFF_INITIAL` | 30 | Initial backoff delay (seconds) |
| `CO_BACKOFF_MAX` | 300 | Maximum backoff delay (seconds) |
| `CO_MAX_BUDGET_USD` | 5.00 | Spending cap per task (cumulative across retries) |
| `CO_MAX_RUNTIME` | 7200 | Maximum runtime in seconds (default 2h) |
| `CO_FALLBACK_MODEL` | sonnet | Model to use when primary is overloaded |
| `CO_PERMISSION_MODE` | bypassPermissions | Claude permission mode |
| `CO_NOTIFY_URL` | *(empty)* | ntfy.sh topic URL for notifications |

All settings can be overridden via CLI flags (e.g., `--budget 10`, `--timeout 3600`).

## CLI Reference

```
claude-offline [OPTIONS] "task description"

OPTIONS:
  --project <dir>         Working directory (default: current)
  --name <name>           Human-readable task name
  --model <model>         Model override
  --budget <usd>          Spending cap
  --timeout <seconds>     Maximum runtime
  --retries <n>           Retry attempts
  --fallback <model>      Fallback model on overload
  --permission-mode <m>   Permission mode
  --notify <url>          ntfy.sh URL for notifications
  --resume <session-id>   Resume an existing Claude session

SUBCOMMANDS:
  --status                List running offline sessions
  --logs [name]           Tail session log
  --stop [name]           Gracefully stop a session
  --result [name]         Show structured result
  --history               Show task history
  -h, --help              Show help
```

## Shell Aliases

| Alias | Command |
|-------|---------|
| `cco` | `claude-offline` |
| `ccos` | `claude-offline --status` |
| `ccol` | `claude-offline --logs` |
| `ccor` | `claude-offline --result` |
| `ccoh` | `claude-offline --history` |

## Log Files

- `~/.local/log/claude-offline/<session>.log` -- human-readable terminal output
- `~/.local/log/claude-offline/<session>.jsonl` -- structured JSON Lines (one record per attempt + final summary)

## Retry Behavior

When Claude Code fails (rate limit, network error, API error):

1. Captures the session ID from the failed attempt
2. Waits with exponential backoff (30s, 60s, 120s, 240s)
3. Resumes the session with `--resume <session-id>` so Claude has context of prior work
4. Subtracts cost from remaining budget to prevent overspend
5. Stops after budget exhaustion, timeout, or max retries
