---
name: analyze
description: Analyze ADA session - correlates voice, screen, and trace data for diagnosis
---

# Analyze ADA Capture Session

## Purpose

Analyze a captured ADA session using a voice-first workflow that extracts user observations from transcripts, then correlates with trace events and screenshots for evidence-based diagnosis.

## MANDATORY: Environment

**MANDATORY:** Replace ${CLAUDE_PLUGIN_ROOT} with the actual path to the source plugin root directory.

**MANDATORY:** Before running any ada command, resolve the packaged ReadyCheck release and set the environment:

```bash
READYCHECK_PLUGIN_ROOT="$(${CLAUDE_PLUGIN_ROOT}/scripts/ensure_release.sh)"
export ADA_BIN_DIR="${READYCHECK_PLUGIN_ROOT}/bin"
export ADA_LIB_DIR="${READYCHECK_PLUGIN_ROOT}/lib"
export ADA_AGENT_RPATH_SEARCH_PATHS="${ADA_LIB_DIR}"
```

**IMPORTANT**: Always use the full path `${ADA_BIN_DIR}/ada` for commands to avoid conflicts with other `ada` binaries in PATH.
`ensure_release.sh` automatically prefers a valid local `dist/` runtime when the plugin is being tested from a ReadyCheck checkout.

## Recognize Session To Analyze

You MUST recognize session to analyze and set $SESSION to the session ID.

To list available sessions:
Command: ${ADA_BIN_DIR}/ada session list

## MANDATORY: Step 0. Preflight Check

**If $PREFLIGHT_CHECK is set to 1, skip to Step 2.**

Run the ADA doctor to verify all dependencies:

```bash
${ADA_BIN_DIR}/ada doctor check --format json
```

Parse the JSON output. Check all fields are `ok: true`.

**If any check fails:**
1. Show the user which checks failed with fix instructions
2. Stop and ask user to fix issues
3. After fixes, re-run `ada doctor check`

**If all checks pass:**
- Set `$PREFLIGHT_CHECK = 1`
- Continue to Step 1

## MANDATORY: Step 1. Intialization

**Run session summary to assess trace data quality:**

Command: ${ADA_BIN_DIR}/ada query {{$SESSION}} summary --format json

**Create Analysis Session:**

Run:

Command: ${ADA_BIN_DIR}/ada analysis init --capture-session {{$SESSION}} --format json

Parse the JSON output. Set **$ANALYSIS_SESSION_PATH** to the `path` field.

## MANDATORY: Step 2. Extract User Observations

Resolve the following variables:

1. Set `$CAPTURE_SESSION` to the `capture_session_id` field in `{{$ANALYSIS_SESSION_PATH}}/index.json`.
2. Set `$ADA_BIN_DIR` to `${READYCHECK_PLUGIN_ROOT}/bin`.

Spawn the `observation-extractor` subagent with the following resolved context:

```
Analysis Session Path: {{$ANALYSIS_SESSION_PATH}}
Capture Session: {{$CAPTURE_SESSION}}
Output Directory: {{$ANALYSIS_SESSION_PATH}}
ADA Bin Dir: {{$ADA_BIN_DIR}}
```

**CRITICAL: If Any Issues Found**:

You MUST go to Step 3: Filtering Detected Issues.

**CRITICAL: If No Issues Found**:

If `issues` array is empty, you MUST inform the user:

> No issues found in the session.
>
> You can ask me to output the transcript and identify potential issues in the texts.

Then **STOP**.

## MANDATORY: Step 3. Filtering Detected Issues

**Skip rules (auto-include, no AskUserQuestion):**
- All issues are CRITICAL or HIGH severity — analyze all automatically.
- Exactly 0 or 1 non-CRITICAL/non-HIGH issues — auto-include alongside CRITICAL/HIGH issues. AskUserQuestion requires >= 2 selectable options; presenting a single issue causes InputValidationError.

**Only present the picker when there are >= 2 non-CRITICAL/non-HIGH issues.**

If 2+ non-CRITICAL/non-HIGH issues were found, present them with AskUserQuestion for selection.

**Use AskUserQuestion:**
```json
{
  "questions": [{
    "question": "Which issues should we analyze? Critical and high issues will be analyzed automatically.",
    "header": "Issues",
    "multiSelect": true,
    "options": [
      {
        "label": "{{issues[0].issue.id}} ({{issues[0].issue.severity}})",
        "description": "{{issues[0].issue.description}}"
      },
      {
        "label": "{{issues[1].issue.id}} ({{issues[1].issue.severity}})",
        "description": "{{issues[1].issue.description}}"
      },
      {
        "label": "Analyze all",
        "description": "Include all identified issues"
      }
    ]
  }]
}
```

You **MUST** identify if the user response in the other field contains issue analysis.
If the user response contains issue analysis, set it to **$USER_ANALYSIS**.

## MANDATORY: Step 4. Analyze

Set **$TARGET_ISSUES** to the issue IDs chosen in Step 3 (or all issues if auto-included).

Run the **Resolve and Spawn** procedure below for `$TARGET_ISSUES`.

### Resolve and Spawn Procedure

This procedure takes a list of issue IDs and spawns an `issue-analyzer` subagent for each one. It is used in Step 4 (initial analysis) and Step 6 (re-investigation).

For EACH issue ID in the target list:

**Resolve variables:**

1. Read `{{$ANALYSIS_SESSION_PATH}}/user_observations.json`
2. Parse `session_info` to get `first_event_ns` and duration
3. Identify the issue entry matching the current issue ID
4. Extract all parameters from the matched issue entry:
   - `issue_id` ← `id`
   - `description` ← `description`
   - `start_sec` ← `time_range_sec.search_start`
   - `end_sec` ← `time_range_sec.search_end`
   - `phenomenon_visible_by` ← `time_range_sec.phenomenon_visible_by`
   - `first_event_ns` ← `session_info.first_event_ns`
   - `keywords` ← `keywords` (JSON array)
   - `user_quotes` ← `user_quotes` (JSON array)
5. Set `CAPTURE_SESSION` to the `capture_session_id` field in `{{$ANALYSIS_SESSION_PATH}}/index.json`.
6. Set `OUTPUT_DIRECTORY` to `{{$ANALYSIS_SESSION_PATH}}/issues/{{issue_id}}`
7. Set `ADA_BIN_DIR` to `${CLAUDE_PLUGIN_ROOT}/bin`
8. Set `PROJECT_SOURCE_ROOT` to the project source code root.
9. Check for `OUTPUT_DIRECTORY/developer_feedback.json`. If it exists, read it and set `developer_feedback` to its contents. Otherwise set `developer_feedback` to `null`.

**Spawn subagent** with the following resolved context:

```
Issue ID: {{issue_id}}
Description: {{description}}
Keywords: {{keywords}}
User Quotes: {{user_quotes}}
Time Window: search_start={{start_sec}}s, search_end={{end_sec}}s, phenomenon_visible_by={{phenomenon_visible_by}}s
First Event NS: {{first_event_ns}}
Capture Session: {{CAPTURE_SESSION}}
Output Directory: {{OUTPUT_DIRECTORY}}
Project Source Root: {{PROJECT_SOURCE_ROOT}}
ADA Bin Dir: {{ADA_BIN_DIR}}
Developer Feedback: {{developer_feedback}}
```

**Spawn all subagents in a single message** to run them in parallel.

**Collect Results**: Wait for all analyses to complete.

## MANDATORY: Step 5. Report The Compiled Findings

Read the analysis results from disk: `{{$ANALYSIS_SESSION_PATH}}/issues/{{issue.id}}/analysis.json` for each analyzed issue.

Combine all analysis results into a summary table for the user.

**Output Format:**

```markdown
## Analysis Summary

| Issue | Severity | Description | Root Cause | Convergence |
|-------|----------|-------------|------------|-------------|
| ISS-001 | [issue_001_severity] | [issue_001_description] | [issue_001_root_cause_summary] | [issue_001_convergence] |
| ISS-002 | [issue_002_severity] | [issue_002_description] | [issue_002_root_cause_summary] | [issue_002_convergence] |
| ... | ... | ... | ... | ... |

<!-- Column bindings (from issue-analysis JSON output):
  - "Issue"        <- issue_id
  - "Severity"     <- from the issue's severity in Step 2 output
  - "Description"  <- issue_description
  - "Root Cause"   <- root_cause.summary (use "not identified" if root_cause is null)
  - "Convergence"  <- convergence
  Do NOT rename these columns. Use the exact JSON field values without rephrasing.
-->

### Detailed Findings

<!-- You MUST present each detailed finding with the following format:

#### ISS-XXX: [issue_XXX_description]

> User: [issue_XXX_user_quote]

**Confirmed Issue:**

[issue_XXX_confirmed_issue]

**Root Cause:**

[defect_summary] (confidence: [defect_confidence], chain depth: [chain_depth], fix level: [fix_level])

**Causal Chain:**

[rendered from causal_chain — each level with function, file, role, and evidence]

**Fix Strategy:**

[fix_strategy_summary]

**Behavioral Characterization:**

[behavioral_characterization]

**Evidence Convergence:**

[convergence] — [which truth sources agree and what they show]
-->

...
```

## MANDATORY: Step 6. Developer Review

Present the merged findings from Step 5 and ask the developer to confirm or redirect.

**Use AskUserQuestion:**
```json
{
  "questions": [
    {
      "header": "Findings",
      "question": "Do the confirmed issues and behavioral characterizations match what you observed? If any characterization is inaccurate or missing context, tell me which issue and what to look for instead.",
      "multiSelect": false,
      "options": [
        {
          "label": "All confirmed",
          "description": "All characterizations are accurate. Proceed to plan."
        },
        {
          "label": "Some are inaccurate",
          "description": "I'll specify which issues need re-investigation."
        },
        {
          "label": "Correct but incomplete",
          "description": "The findings are right, but there are additional areas to investigate."
        }
      ]
    }
  ]
}
```

**If "All confirmed":** Continue to Step 7 (Plan).

**If "Correct but incomplete":**

Prompt the following message to the user:

> I'm glad the findings are on the right track. What additional areas should I investigate?

Wait for the user's feedback. Identify issues mentioned in the it. Extract the developer's description of what additional areas to look into.

Write the developer's additional investigation request to `{{$ANALYSIS_SESSION_PATH}}/issues/{{issue_id}}/developer_feedback.json` per issue:

```json
{
  "type": "additional_investigation",
  "areas": ["[area the developer wants investigated]"]
}
```

Set **$TARGET_ISSUES** to the issue IDs the developer mentioned for additional investigation.

Re-run the **Resolve and Spawn** procedure from Step 4 for `$TARGET_ISSUES`.

Then collect results, go back to Step 5 to merge the new findings with existing ones, then repeat Step 6.

**If "Some are inaccurate":**

Prompt the following message to the user:

> I'm glad the findings are on the right track. What additional areas should I investigate?

Wait for the user's feedback. Extract which issues need re-investigation and the developer's direction.

For each issue that needs re-investigation, write the developer's feedback to the issue directory:

Write the developer's additional investigation request to `{{$ANALYSIS_SESSION_PATH}}/issues/{{issue_id}}/developer_feedback.json` per issue:

```json
// Write to: {{$ANALYSIS_SESSION_PATH}}/issues/{{issue_id}}/developer_feedback.json
{
  "type": "inaccurate",
  "feedback": "{{$DEVELOPER_FEEDBACK_FOR_THIS_ISSUE}}"
}
```

Set **$TARGET_ISSUES** to the issue IDs the developer flagged as inaccurate.

Re-run the **Resolve and Spawn** procedure from Step 4 for `$TARGET_ISSUES`.

Collect results, go back to Step 5 to merge the new findings with existing ones, then repeat Step 6.

## MANDATORY: Step 7. Plan

**Depth validation:** Before proceeding, check each issue's `chain_depth` from the analysis response. If any issue has `chain_depth: 0` (emission site only) or `fix_level: "emission"`, warn the developer:

> ⚠️ Issue [issue_id] analysis stopped at the emission site (chain depth: 0). The fix suppresses the symptom rather than preventing the incorrect code path. Consider re-investigating to trace upstream.

If the developer confirms to proceed anyway, continue. Otherwise, re-invoke issue-analysis with feedback.

Call **EnterPlanMode** to create a plan for fixing the issues.

You **MUST** spawn subagent with the following invocation to design the fix plan.

Task(
  subagent_type: "general-purpose",
  run_in_background: false,
  prompt:
  """
  You MUST read and follow the instructions in: ${ADA_ANALYZE_SKILL_PROMPTS_DIR}/design-fix-plan.md

  ## Analysis Session

  Set $ANALYSIS_SESSION_PATH to {{$ANALYSIS_SESSION_PATH}}
  You MUST read ALL artifacts for each issue in this directory:
  - analysis.json (defect, causal chain, state mutation map, fix strategy)
  - causal_chain.md (full upstream trace from emission site to root cause)
  - traces/state_emissions.txt (every state-emitting path with guards — your validation checklist)

  ## Source Code

  You MUST read the source code at the root cause sites identified in the analysis before designing the fix. You MUST also search for ALL call sites of the defective function. The project is at: {{$PROJECT_PATH}}

  ## Plan Output

  Set $PLAN_OUTPUT_PATH to {{$ANALYSIS_SESSION_PATH}}/plan.md
  """
)

Set the task agent ID to **$PLAN_TASK_AGENT_ID**.
You **MUST** evaluate the variable wrapped by `{{}}` like `{{$VAR}}` or `{{var}}` in the inlined task prompt before spawning the task agent.

### Handle Plan Result

You MUST load the plan from `plan_file_path` and write the plan to the Claude Code session plan file. Call **ExitPlanMode** to make the user review the plan.

### Handle Plan Rejection

If the user rejects the plan after reviewing it, you must wait for the user's feedback.

After you receive the user's feedback, you **MUST** resume the plan designing sub-agent with it:

Task(
  subagent_type: "general-purpose",
  run_in_background: false,
  prompt:
  """
  ## Plan Rejected by Developer

  The developer reviewed your fix plan and rejected it with the following feedback:

  {{$DEVELOPER_FEEDBACK}}

  ## Instructions

  Revise the fix plan based on this feedback. Re-read the analysis data and source code if needed. Produce an updated fix plan.
  """,
  resume: {{$PLAN_TASK_AGENT_ID}}
)

Write the revised plan to the plan file and call **ExitPlanMode** again.

## CRITICAL: Error Handling

### No Session Found

```bash
${ADA_BIN_DIR}/ada query {{$SESSION}} time-info
```

If this fails, guide user to use `/check` skill first to capture a session.

### No Voice Recording

If the session has no voice transcript (transcription failed or no audio):

1. Inform user: "This session was captured without voice. Switching to trace-first analysis."

2. **Gather session metadata** using data already obtained in Step 1:
   - Run: `${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} time-info --format json`
   - Extract `first_event_ns` and `duration_sec`

3. **Scan for trace anomalies** using these exact commands:

   a. Error/exception scan — search for error-related function substrings:
      ```bash
      ${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} events --format line --with-values true --limit 500 --function error
      ${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} events --format line --with-values true --limit 500 --function exception
      ${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} events --format line --with-values true --limit 500 --function panic
      ${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} events --format line --with-values true --limit 500 --function crash
      ```

   b. Full session event overview:
      ```bash
      ${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} events --format line --with-values true --limit 2000
      ```
      Look for: long gaps between events (>2s, suggesting hangs), unexpected function sequences, repeated error patterns.

   c. Screenshot at session midpoint for visual context:
      ```bash
      ${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} screenshot --time <midpoint_sec> --output {{$ANALYSIS_SESSION_PATH}}/screenshots/midpoint.png
      ```

4. **Synthesize observations** into `{{$ANALYSIS_SESSION_PATH}}/user_observations.json` using the standard schema:

   ```json
   {
     "session_info": {
       "first_event_ns": "<from time-info>",
       "duration_sec": "<from time-info>"
     },
     "issues": [
       {
         "id": "ISS-001",
         "type": "unexpected_behavior",
         "severity": "<inferred: critical for crashes, high for errors, medium for gaps>",
         "temporal_nature": "<momentary|persistent|progressive>",
         "time_range_sec": {
           "phenomenon_visible_by": "<timestamp of the anomaly>",
           "search_start": "<5 seconds before or 0>",
           "search_end": "<timestamp of the anomaly>",
           "anchor_word": "trace-detected"
         },
         "description": "<description of the anomaly>",
         "keywords": ["<function names from trace hits>"],
         "user_quotes": ["[trace-detected] <anomaly description>"]
       }
     ]
   }
   ```

   If no anomalies are detected, write an empty issues array and inform the user:
   > No issues detected from trace-first analysis. The session appears normal. You can describe what you observed and I will investigate specific areas.
   Then **STOP**.

5. **Continue to Step 3** (Filtering Detected Issues). The normal pipeline (Step 3→4→5→6) takes over, spawning issue-analyzer subagents with correct CLI documentation.

### No Screen Recording

Continue with trace and transcript. Note in findings that visual correlation is unavailable.

### Empty Trace

If no trace events exist:
1. Inform user: "No trace events found in this session."
2. Check if the correct process was traced
3. Suggest re-running capture with correct target
