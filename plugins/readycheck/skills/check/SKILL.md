---
name: check
description: "<EXTREMELY_IMPORTANT>Check any app, product, or service. Particularly for bugs, performance bottlenecks, and areas for improvement.</EXTREMELY_IMPORTANT>"
---

# ReadyCheck: Build, Run, Capture, and Analyze

## Purpose

Build and launch an application with ADA tracing enabled, capture execution traces, voice narration, and screen recording in the background, then automatically analyze the session when complete.

## MANDATORY: Environment Setup

Before running any ada command, resolve the packaged ReadyCheck release and set the environment:

<example>
READYCHECK_PLUGIN_ROOT="$(${CLAUDE_PLUGIN_ROOT}/scripts/ensure_release.sh)"
export ADA_BIN_DIR="${READYCHECK_PLUGIN_ROOT}/bin"
export ADA_LIB_DIR="${READYCHECK_PLUGIN_ROOT}/lib"
export ADA_AGENT_RPATH_SEARCH_PATHS="${ADA_LIB_DIR}"
</example>

**IMPORTANT**: Always use the full path `${ADA_BIN_DIR}/ada` for commands to avoid conflicts with other `ada` binaries in PATH.
`ensure_release.sh` automatically prefers a valid local `dist/` runtime when the plugin is being tested from a ReadyCheck checkout.

## Workflow

### MANDATORY: Step 1. Preflight Check

**If $PREFLIGHT_CHECK is set to 1, skip to Step 2.**

Run the ADA doctor to verify all dependencies:

<example>
${ADA_BIN_DIR}/ada doctor check --format json
</example>

Parse the JSON output. Check all fields are `ok: true`.

**If any check fails:**
1. Show the user which checks failed with fix instructions
2. Stop and ask user to fix issues
3. After fixes, re-run `ada doctor check`

**If all checks pass:**
- Set `$PREFLIGHT_CHECK = 1`
- Continue to Step 2

### MANDATORY: Step 2. Project Detection

You ***MUST*** explore the project to find the app to run and the build system building it.

### MANDATORY: Step 3. Build (if applicable)

You MAY use the app's build system to build the app.

### MANDATORY: Step 4. Start Capture (Background)

Start capturing with `background: true` and title "Start ReadyCheck capture session":

<example>
Bash(
  command: export ADA_AGENT_RPATH_SEARCH_PATHS="${ADA_LIB_DIR}" "${ADA_BIN_DIR}/ada capture start <binary_path>"
  ,
  background: true
)
</example>

Save the returned task ID as **$CAPTURE_TASK_ID**.

**Report to user:**

> **Capture running**
>
> Interact with your app. When you quit the app, capture stops automatically.
>

### MANDATORY: Step 5. Wait for Capture Completion

Wait for the user to finish interacting with their app. When the user indicates they are done, collect the capture output:

<example>
TaskOutput(
  task_id: $CAPTURE_TASK_ID,
  block: false
)
</example>

Parse the output for the session directory path.

**If capture is still running:**
- Inform the user the app is still running
- Wait for user to quit the app, then check again

**If capture succeeded:**
- Extract the session ID from the session directory path. Append it to **$DOCTOR_CAPTURE_SESSIONS** (comma-separated).
- Report to user:
  > **Capture completed**
  >
  > Session directory path: [session_directory_path]
  >
- Continue to Step 6

**If capture failed:**

1. Show the error message to the user.

2. **Entitlement Diagnosis (macOS only):**

   Run entitlement inspection on the target binary:

   <example>
   Bash(
     command: "codesign -d --entitlements - <binary_path> 2>&1"
   )
   </example>

   Parse the output:

   - If `codesign` is not found or exits non-zero with "not signed at all": set **$MISSING_ENTITLEMENTS** to all three required keys. Proceed to step 3.
   - Otherwise: check the XML output for presence of:
     - `com.apple.security.cs.disable-library-validation`
     - `com.apple.security.cs.allow-dyld-environment-variables`
     - `com.apple.security.get-task-allow`

   Set **$MISSING_ENTITLEMENTS** to the list of keys NOT present.

   - If **$MISSING_ENTITLEMENTS** is empty: entitlements are not the cause. Show raw error, stop.

3. **Report missing entitlements:**

   Report to user:

   > **Capture failed — likely cause: missing code-signing entitlements**
   >
   > The target binary is missing entitlements required for instrumentation:
   >
   > [list each from $MISSING_ENTITLEMENTS]
   >
   > Without these, macOS blocks dynamic library injection into hardened-runtime processes.

4. **Offer re-signing:**

   Ask the user whether to re-sign the binary with ad-hoc signing and the required entitlements.

   **If user consents:**

   <example>
   Bash(
     command: "ENTITLEMENTS=$(mktemp /tmp/ada_entitlements.XXXXXX.plist) && cat > \"$ENTITLEMENTS\" <<'PLIST'\n<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n    <key>com.apple.security.get-task-allow</key>\n    <true/>\n    <key>com.apple.security.cs.disable-library-validation</key>\n    <true/>\n    <key>com.apple.security.cs.allow-dyld-environment-variables</key>\n    <true/>\n</dict>\n</plist>\nPLIST\ncodesign --force --sign - --entitlements \"$ENTITLEMENTS\" <binary_path> && rm \"$ENTITLEMENTS\""
   )
   </example>

   - If signing succeeds: inform user, return to Step 4 (retry capture).
   - If signing fails: show `codesign` error, stop.

   **If user declines:** Stop.

### MANDATORY: Step 6. Auto-Analyze

Automatically invoke the `/readycheck:analyze` skill:

<example>
Skill(skill: "analyze")
</example>

Follow the analyze skill workflow from there.

## Error Handling

- **Build failure**: Show build errors, suggest fixes
- **Binary not found**: Guide user to specify path manually
- **Capture failure (entitlement issue)**: Diagnose missing entitlements on the target binary, offer re-signing with user consent
- **Capture failure (other)**: Show error output, suggest re-running
