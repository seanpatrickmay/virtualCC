# Handoff

Transfer work from your local machine to the VCC when going offline.

## Quick Start

```bash
# From your laptop, inside a git project:
handoff "continue implementing the nutrition tracking feature"
```

This will:
1. Commit your uncommitted changes to a `handoff/<branch>-<timestamp>` branch
2. Push the branch to origin
3. SSH to the VCC, clone/fetch the repo
4. Launch `claude-offline` with full context about your work
5. Print monitoring commands

You can then close your laptop.

## How It Works

The handoff script captures your current work context and transfers it to the VCC:

**What gets transferred:**
- All uncommitted changes (committed to a temporary handoff branch)
- `git diff --stat` summary
- Detailed diff (truncated to 200 lines)
- Recent commit history (last 10 commits)
- CLAUDE.md project instructions (if present)
- Your task description

**What doesn't transfer:**
- Running server state or database state
- Environment variables specific to your local machine
- Claude Code conversation history (VCC gets a fresh session with context)
- Binary files or large assets may be slow over git

## Installation

The `handoff` script is designed to run on your **local laptop**. Copy it from the VCC:

```bash
# On your laptop:
scp vcc:~/.local/bin/handoff ~/.local/bin/handoff
chmod +x ~/.local/bin/handoff
```

Create a config file at `~/.config/handoff/config`:

```bash
VCC_HOST=vcc        # SSH hostname (from ~/.ssh/config)
VCC_USER=dev        # VCC username
```

## CLI Reference

```
handoff [OPTIONS] ["task description"]

OPTIONS:
  --branch <name>    Custom handoff branch name
  --no-push          Prepare context but don't execute on VCC
  --dry-run          Show what would happen without doing it
  --project <path>   Override project path on VCC
  --host <hostname>  VCC SSH hostname (default: from config)
  --check            Verify VCC connectivity without executing
  -h, --help         Show help
```

## Examples

```bash
# Basic handoff with task description
handoff "fix the broken test suite and commit the fix"

# Preview what would happen
handoff --dry-run "refactor the API layer"

# Verify VCC is reachable
handoff --check

# Custom branch name
handoff --branch my-feature "implement user authentication"

# Just push the WIP branch without launching Claude
handoff --no-push "notes about what to continue"
```

## After Handoff

Monitor from any machine with SSH access to the VCC:

```bash
# Check session status
ssh vcc "claude-offline --status"

# View live output
ssh vcc "claude-offline --logs"

# Attach to the tmux session
ssh vcc -t "tmux attach -t offline-*"

# See the result when done
ssh vcc "claude-offline --result"
```

Or check from your phone if [phone monitoring](phone-monitoring.md) is set up.

## Git Workflow

The handoff creates a branch like `handoff/main-20260330-143000`:

```
main ──○──○──○──
                 \
handoff/main-... ──● (WIP commit)
                    \
                     ●──●──● (Claude's commits on VCC)
```

When you're back, review and merge:

```bash
git fetch origin
git log origin/handoff/main-20260330-143000
git merge origin/handoff/main-20260330-143000  # or cherry-pick
```
