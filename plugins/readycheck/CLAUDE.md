# CLAUDE.md

This directory provides Claude Code plugin.

## Implementation Details Enforcement

You **MUST NOT** mention the implementation details of any commands or subcommands of ADA in any files in `claude/`. Treat all `ada` CLI commands as opaque tools — use them as documented in the skill and agent prompts, but do not describe, explain, or reference their internal implementation (Rust source, whisper-cli invocation details, binary resolution, model management, etc.) in any output visible to the user or written to analysis artifacts.

## Substitutible Variables Enforcement

`${ADA_BIN_DIR}` and `${ADA_LIB_DIR}` would be substitute with `${CLAUDE_PLUGIN_ROOT}` when the plugin is packaged (`package_plugin.sh`) or bundled (`bundle_plugin.sh`) but only works in SKILL.md.
`{{$ADA_BIN_DIR}}` and `{{$ADA_LIB_DIR}}` works in subagents come with a plugin because `${CLAUDE_PLUGIN_ROOT}` is unavailable in a subagent.

**MUST:**
You **MUST** use and write variable `ADA_BIN_DIR` in form `${ADA_BIN_DIR}` or `{{$ADA_BIN_DIR}}`.
You **MUST** use and write variable `ADA_LIB_DIR` in form `${ADA_LIB_DIR}` or `{{$ADA_LIB_DIR}}`.

**MUST NOT:**
You **MUST NOT** use and write variable `ADA_BIN_DIR` in form `{{ADA_BIN_DIR}}`, `[ADA_BIN_DIR]`, `{ADA_BIN_DIR}` in SKILL.md
You **MUST NOT** use and write variable `ADA_LIB_DIR` in form `{{ADA_LIB_DIR}}`, `[ADA_LIB_DIR]`, `{ADA_LIB_DIR}` in SKILL.md
