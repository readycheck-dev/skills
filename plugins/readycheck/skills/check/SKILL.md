---
name: check
description: "<MANDATORY>Check any app, product, or service. Particularly for bugs, performance bottlenecks, and areas for improvement.</MANDATORY>"
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

Start capturing with `run_in_background: true` and title "Start ReadyCheck capture session":

<example>
Bash(
  command: "${ADA_BIN_DIR}/ada capture start <binary_path>",
  run_in_background: true
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
- Report to user:
  > **Capture completed**
  >
  > Session directory path: [session_directory_path]
  >
- Continue to Step 6

**If capture failed:**
- Show the error message to the user
- Stop

### MANDATORY: Step 6. Auto-Analyze

Automatically invoke the analyze skill:

<example>
Skill(skill: "analyze")
</example>

Follow the analyze skill workflow from there.

### MANDATORY: Step 7. Post-Fix Verification Capture

After the plan has been executed and code changes are applied:

1. **Re-build** the application using the same build process from Step 3.

2. **Start a new capture session** using the same binary path and arguments as Step 4:

<example>
Bash(
  command: "${ADA_BIN_DIR}/ada capture start <binary_path>",
  run_in_background: true
)
</example>

Save the returned task ID as **$POST_FIX_CAPTURE_TASK_ID**.

3. **Report to user:**

> **Post-fix verification capture running**
>
> Please reproduce the same workflow you performed earlier.
> This allows me to verify the fix worked AND that nothing else broke.
> Quit the app when done.

4. Wait for the user to finish. Collect the post-fix session when the app quits. Set **$POST_FIX_SESSION**.

### MANDATORY: Step 8. Regression Verification

Read the plan file generated during Step 6's analysis workflow. Parse the `## Modification Impact Analysis` section.

**8a. Symptom Resolution Check:**

For each issue in the plan's `## Issues` table, verify the original symptom is resolved in the post-fix capture. Use screenshots and trace queries against `$POST_FIX_SESSION` to confirm.

**8b. Modification Impact Verification:**

For each row in the `## Modification Impact Analysis` table:

1. Re-run the same trace queries from the Evidence column against `$POST_FIX_SESSION`
2. Compare: does the runtime behavior match the expected post-fix behavior?
3. If the verdict was SAFE but the post-fix behavior differs unexpectedly from the baseline, flag as a potential regression

**Report to user:**

> **Verification Results**
>
> **Symptom Resolution:**
> - [PASS/FAIL]: [description per issue]
>
> **Modification Impact:**
> - [Modification Point 1]: [PASS — behavior matches expectations / FAIL — unexpected change detected]
> - [Modification Point 2]: [PASS/FAIL]
>
> **Overall:** [All checks passed / N issues detected]

If any check fails, show the specific trace query results that differ from the baseline and suggest investigation steps.

## Error Handling

- **Build failure**: Show build errors, suggest fixes
- **Binary not found**: Guide user to specify path manually
- **Capture failure**: Show error output, suggest re-running
