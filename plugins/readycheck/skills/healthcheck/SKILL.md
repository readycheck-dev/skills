---
name: healthcheck
description: ADA system health check and diagnostic export
disable-model-invocation: true
---

# Healthcheck

## Purpose

Check system health and dependencies for ADA capture and analysis workflows. Create a diagnostic ZIP bundling capture sessions, analysis sessions, and Claude Code session transcripts from the current session.

## Environment

**MANDATORY:** Before running any ada command, resolve the packaged ReadyCheck release and set the environment:

```bash
READYCHECK_PLUGIN_ROOT="$(${CLAUDE_PLUGIN_ROOT}/scripts/ensure_release.sh)"
export ADA_BIN_DIR="${READYCHECK_PLUGIN_ROOT}/bin"
export ADA_LIB_DIR="${READYCHECK_PLUGIN_ROOT}/lib"
export ADA_AGENT_RPATH_SEARCH_PATHS="${ADA_LIB_DIR}"
```

`ensure_release.sh` automatically prefers a valid local `dist/` runtime when the plugin is being tested from a ReadyCheck checkout.

## MANDATORY: Step 1. Preflight Check

**If $PREFLIGHT_CHECK is set to 1:**
- Inform user: "Preflight already passed this session."
- Still run `ada doctor check` to show current status (user explicitly requested it)

**If $PREFLIGHT_CHECK is not set:**
- Run `ada doctor check`
- If all checks pass, set `$PREFLIGHT_CHECK = 1`

Run the doctor command:

```bash
${ADA_BIN_DIR}/ada doctor check
```

For JSON output (useful for programmatic parsing):

```bash
${ADA_BIN_DIR}/ada doctor check --format json
```

Present the results to the user:

- Items marked with a checkmark are ready to use
- Items marked with an X need attention with fix instructions

### Example Text Output

```
ADA Doctor
==========

Core:
  ✓ frida agent: /path/to/libfrida_agent.dylib

Analysis:
  ✓ whisper: /path/to/bin/whisper-cli
  ✓ ffmpeg: /path/to/bin/ffmpeg

Status: All checks passed
```

### Example JSON Output

```json
{
  "status": "ok",
  "checks": {
    "frida_agent": { "ok": true, "path": "/path/to/lib/libfrida_agent.dylib" },
    "whisper": { "ok": true, "path": "/path/to/bin/whisper-cli" },
    "ffmpeg": { "ok": true, "path": "/path/to/bin/ffmpeg" }
  },
  "issues_count": 0
}
```

### Checks Performed

| Category | Check | Description |
|----------|-------|-------------|
| **Core** | Frida agent library | Checks `ADA_AGENT_RPATH_SEARCH_PATHS` or known paths for `libfrida_agent.dylib` |
| **Analysis** | Whisper installed | Checks for whisper-cli (bundled) or whisper (system) |
| **Analysis** | FFmpeg installed | Checks for bundled or system FFmpeg |

**NOT checked by doctor** (checked at runtime when capture starts):
- Screen recording permission - Triggers OS dialog if checked
- Microphone access - Triggers OS dialog if checked

### Issue Resolution

If issues are found:

1. Show which components are affected (capture vs analysis)
2. Provide exact fix commands
3. Suggest re-running doctor after fixes

#### Common Fixes

- **Frida agent not found**: Set `ADA_AGENT_RPATH_SEARCH_PATHS` environment variable
- **Whisper not found**: Run `./utils/init_media_tools.sh` (development) or reinstall the plugin (production)
- **FFmpeg not found**: Run `./utils/init_media_tools.sh` (development) or reinstall the plugin (production)

## MANDATORY: Step 2. Resolve Current Claude Code Session

Read the Claude Code session metadata:

```bash
cat ~/.claude/sessions/$PPID.json
```

Parse the JSON output. Extract:
- `sessionId` (UUID)
- `cwd` (working directory path)

Set **$CC_SESSION_ID** to the `sessionId` value.
Set **$CC_CWD** to the `cwd` value.

Derive **$CC_PROJECT_DIR** by replacing every `/` in `$CC_CWD` with `-`.
  - Example: `/Users/wezzard/Projects/ADA` becomes `-Users-wezzard-Projects-ADA`

## MANDATORY: Step 3. Collect ADA Sessions

Read `$DOCTOR_CAPTURE_SESSIONS` (comma-separated capture session IDs).
Read `$DOCTOR_ANALYSIS_SESSIONS` (comma-separated analysis session IDs).

If neither variable is set, inform the user that no ADA sessions were recorded in this Claude Code session. Continue to Step 4 to still bundle the transcript.

For each capture session ID in `$DOCTOR_CAPTURE_SESSIONS`:
- Resolve its directory: `~/.ada/sessions/<session_id>/`

For each analysis session ID in `$DOCTOR_ANALYSIS_SESSIONS`:
- Resolve its directory: `~/.ada/analyses/<analysis_id>/`

## MANDATORY: Step 4. Resolve Claude Code Transcript

The transcript files for this session:
- Main transcript: `~/.claude/projects/{{$CC_PROJECT_DIR}}/{{$CC_SESSION_ID}}.jsonl`
- Subagents directory: `~/.claude/projects/{{$CC_PROJECT_DIR}}/{{$CC_SESSION_ID}}/subagents/`
- Tool results directory: `~/.claude/projects/{{$CC_PROJECT_DIR}}/{{$CC_SESSION_ID}}/tool-results/`

## MANDATORY: Step 5. Create Diagnostic ZIP

Set **$TIMESTAMP** to the current UTC timestamp in `YYYY-MM-DD-HH-MM-SS` format.

Create a ZIP at `{{$CC_CWD}}/readycheck-doctor-{{$TIMESTAMP}}.zip` with the following structure:

```
readycheck-doctor-<timestamp>/
├── capture-sessions/
│   └── <session_id>/            (full copy of ~/.ada/sessions/<id>/)
├── analysis-sessions/
│   └── <analysis_id>/           (full copy of ~/.ada/analyses/<id>/)
└── transcript/
    ├── main.jsonl               (the session JSONL)
    ├── subagents/               (agent-*.jsonl + agent-*.meta.json)
    └── tool-results/            (*.txt files)
```

Use a single `zip` command to bundle all collected directories.

Skip the `capture-sessions/` or `analysis-sessions/` directory if no corresponding sessions were recorded.

## MANDATORY: Step 6. Report

Print to the user:
- The absolute path to the created ZIP
- Number of capture sessions included
- Number of analysis sessions included
- Whether the transcript was included
