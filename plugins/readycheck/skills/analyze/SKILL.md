---
name: analyze
description: Analyze ADA session
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

**MUST:**
You **MUST** proceed to Step 3 whenever the issues array is non-empty.

**MUST NOT:** 
You **MUST NOT** skip issues based on your own assessment. 
You **MUST NOT** declare "no actionable issues" when the issues array contains entries.

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

**Only present the picker when there are 2-3 non-CRITICAL/non-HIGH issues.**

**If 2-3 non-CRITICAL/non-HIGH issues:** Present them individually with AskUserQuestion:

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
        "label": "{{issues[2].issue.id}} ({{issues[2].issue.severity}})",
        "description": "{{issues[2].issue.description}}"
      },
      {
        "label": "Analyze all",
        "description": "Include all identified issues"
      }
    ]
  }]
}
```

**If 4 and 4+ non-CRITICAL/non-HIGH issues:** Too many for individual options. Present the full list in the question text and offer a bulk choice:

```json
{
  "questions": [{
    "question": "Found {{count}} non-CRITICAL/non-HIGH issues:\n{{numbered_list_of_non_critical_issues}}\nAnalyze all, or specify which to skip?",
    "header": "Issues",
    "multiSelect": false,
    "options": [
      {
        "label": "Analyze all",
        "description": "Include all identified issues"
      },
      {
        "label": "Skip some",
        "description": "I'll specify which issues to skip in the text field"
      }
    ]
  }]
}
```

If the user selects "Skip some", read the issue IDs they mention in the text field and exclude those.

You **MUST** identify if the user response in the other field contains issue analysis.
If the user response contains issue analysis, set it to **$USER_ANALYSIS**.

## MANDATORY: Step 4. Analyze

Set **$TARGET_ISSUES** to the issue IDs chosen in Step 3 (or all issues if auto-included).

**MUST:**
You **MUST** spawn the type-specific analyzer subagent for every issue in `$TARGET_ISSUES`.
You **MUST** wait for all subagent analyses to complete before proceeding to Step 5.

**MUST NOT:**
You **MUST NOT** attempt to fix, edit, or patch source code directly based on the observation-extractor output.
You **MUST NOT** skip the analyzer subagents because issues appear "simple" or "straightforward."
You **MUST NOT** substitute your own code reading for the trace-based analysis that analyzers perform.

The type-specific analyzers perform feasibility assessment, architectural constraint detection, data pipeline tracing, and pattern discovery that cannot be replicated by reading source code alone. Skipping them produces superficial fixes that chase symptoms rather than addressing root design issues.

Run the **Resolve and Spawn** procedure below for `$TARGET_ISSUES`.

### Resolve and Spawn Procedure

This procedure takes a list of issue IDs and spawns the appropriate type-specific analyzer subagent for each one. It is used in Step 4 (initial analysis) and Step 6 (re-investigation).

**Subagent routing by issue type:**

| Issue Type | Subagent |
|------------|----------|
| `bug` | `bug-analyzer` |
| `improvement` | `improvement-analyzer` |
| `feature` | `feature-analyzer` |

For EACH issue ID in the target list:

**Resolve variables:**

1. Read `{{$ANALYSIS_SESSION_PATH}}/user_observations.json`
2. Parse `session_info` to get `first_event_ns` and duration
3. Identify the issue entry matching the current issue ID
4. Extract all parameters from the matched issue entry:
   - `issue_id` ← `id`
   - `issue_type` ← `type`
   - `description` ← `description`
   - `temporal_nature` ← `temporal_nature`
   - `anchors` ← `anchors` (JSON array)
   - `first_event_ns` ← `session_info.first_event_ns`
   - `raw_user_quotes` ← `raw_user_quotes` (JSON array)
   - `details` ← `details` (JSON object)
5. Set `CAPTURE_SESSION` to the `capture_session_id` field in `{{$ANALYSIS_SESSION_PATH}}/index.json`.
6. Set `OUTPUT_DIRECTORY` to `{{$ANALYSIS_SESSION_PATH}}/issues/{{issue_id}}`
7. Set `ADA_BIN_DIR` to `${CLAUDE_PLUGIN_ROOT}/bin`
8. Set `PROJECT_SOURCE_ROOT` to the project source code root.
9. Check for `OUTPUT_DIRECTORY/developer_feedback.json`. If it exists, read it and set `developer_feedback` to its contents. Otherwise set `developer_feedback` to `null`.

**Select subagent** based on `issue_type` using the routing table above.

**Spawn subagent** with the following resolved context in **ONE** message to run them in parallel:

```
Issue ID: {{issue_id}}
Description: {{description}}
Temporal Nature: {{temporal_nature}}
Anchors: {{anchors}}
Raw User Quotes: {{raw_user_quotes}}
Details: {{details}}
First Event NS: {{first_event_ns}}
Capture Session: {{CAPTURE_SESSION}}
Output Directory: {{OUTPUT_DIRECTORY}}
Project Source Root: {{PROJECT_SOURCE_ROOT}}
ADA Bin Dir: {{ADA_BIN_DIR}}
Developer Feedback: {{developer_feedback}}
```

You **MUST** spawn all subagents in a **ONE** message to run them in parallel.

**Collect Results**: Wait for all analyses to complete.

## MANDATORY: Step 5. Report The Compiled Findings

Read the analysis results from disk: `{{$ANALYSIS_SESSION_PATH}}/issues/{{issue.id}}/analysis.json` for each analyzed issue.

Combine all analysis results into a summary table for the user. The table format adapts to the issue type.

**Output Format:**

```markdown
## Analysis Summary

| # | Type | Severity | Description | Finding |
|-------|------|----------|-------------|---------|
| ISS-001 | [type] | [severity] | [description] | [finding_summary] |
| ISS-002 | [type] | [severity] | [description] | [finding_summary] |
| ... | ... | ... | ... | ... |

<!-- Column bindings:
  - "Issue"       <- issue_id
  - "Type"        <- issue_type (bug, improvement, feature)
  - "Severity"    <- from the issue's severity in Step 2 output
  - "Description" <- issue_description
  - "Finding"     <- type-specific summary:
      bug:         defect.summary (or "not identified")
      improvement: current_behavior
      feature:     feature_summary
-->

### Detailed Findings

<!-- Present each finding using the appropriate template for its type: -->

<!-- FOR BUG ISSUES: -->

#### ISS-XXX: [description]

> User: [user_quote]

**Confirmed Issue:** [confirmed_issue]

**Root Cause:** [defect_summary] (confidence: [confidence], chain depth: [chain_depth], fix level: [fix_level])

**Causal Chain:** [rendered from causal_chain]

**Fix Strategy:** [fix_strategy_summary]

**Behavioral Characterization:** [behavioral_characterization]

<!-- FOR IMPROVEMENT ISSUES: -->

#### ISS-XXX: [description]

> User: [user_quote]

**Current Behavior:** [scene.current_behavior]

**Affected Components:** [scene.components list with files]

**Modifications:** [modifications with classification and fidelity check]

<!-- FOR FEATURE ISSUES: -->

#### ISS-XXX: [description]

> User: [user_quote]

**Feature Summary:** [claim.user_intent.description]

**Integration:** [integration.capabilities with classification]

**Existing Patterns:** [patterns to follow]

**Complexity:** [overall complexity assessment]
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

**If "All confirmed":**

You **MUST** go to Step 7 (Plan).

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

Then you **MUST** collect results, go back to Step 5 to merge the new findings with existing ones, then repeat Step 6.

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

Then you **MUST** collect results, go back to Step 5 to merge the new findings with existing ones, then repeat Step 6.

## MANDATORY: Step 7. Plan

**Depth validation (bug issues only):** Before proceeding, check each bug issue's `chain_depth` from the analysis response. If any bug issue has `chain_depth: 0` (emission site only) or `fix_level: "emission"`, warn the developer:

> ⚠️ Issue [issue_id] analysis stopped at the emission site (chain depth: 0). The fix suppresses the symptom rather than preventing the incorrect code path. Consider re-investigating to trace upstream.

If the developer confirms to proceed anyway, continue. Otherwise, re-invoke the analyzer with feedback.

Call **EnterPlanMode** to create a plan for the issues.

Yout **MUST** spawn a single planner subagent with ALL issues with the following prompt:

Task(
  subagent_type: "general-purpose",
  run_in_background: false,
  prompt:
  """
  You MUST read and follow the instructions in: ${ADA_ANALYZE_SKILL_PROMPTS_DIR}/plan.md

  ## Analysis Session

  Set $ANALYSIS_SESSION_PATH to {{$ANALYSIS_SESSION_PATH}}
  You MUST read the analysis artifacts for ALL issues in the directory — bugs, improvements, and features together.

  ## Source Code

  You MUST read the source code at the sites identified in the analysis. The project is at: {{$PROJECT_PATH}}

  ## Plan Output

  Set $PLAN_OUTPUT_PATH to {{$ANALYSIS_SESSION_PATH}}/plan.md
  """
)

Set the task agent ID to **$PLAN_TASK_AGENT_ID**.
You **MUST** evaluate the variable wrapped by `{{}}` like `{{$VAR}}` or `{{var}}` in the inlined task prompt before spawning the task agent.

### Handle Plan Result

Read the plan file at `plan_file_path` and write it to the Claude Code session plan file.
Then call **ExitPlanMode**.
Once the plan has been approved, you **MUST** execute the plan.

#### Plan Content Integrity Rules

When transferring the planner's output to the session plan file, you **MUST NOT**:

1. **MUST NOT summarize** — do not reduce multi-step analysis into bullet points or one-liners.
2. **MUST NOT drop sections** — every section the planner wrote (architecture diagrams, state traces, before/after trees, algorithm pseudocode, validation traces, API verification) must appear in the session plan file.
3. **MUST NOT condense** — do not merge separate steps, issues, or design blocks into combined paragraphs.
4. **MUST NOT paraphrase** — do not restate the planner's content in different words. Use the planner's exact wording.
5. **MUST NOT reformat structure** — preserve the planner's heading hierarchy, code blocks, tables, and numbered lists as-is.
6. **MUST NOT inject commentary** — do not add your own summary, introduction, or "remaining changes" wrapper around the plan content.

The plan file produced by the planner is the **single source of truth**. Copy it faithfully. If a user-installed skill needs to optimize the plan, that skill will do so on its own terms — your job is to preserve the planner's output intact.

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

Read the revised plan file and write it to the session plan file. The **Plan Content Integrity Rules** above apply identically. Then call **ExitPlanMode** again.

## CRITICAL: Error Handling

### No Session Found

```bash
${ADA_BIN_DIR}/ada query {{$SESSION}} time-info
```

If this fails, guide user to use `/check` skill first to capture a session.

### No Voice Recording

If the session has no voice transcript (transcription failed or no audio):

Inform user:
> No voice recording was found in this session. Without voice observations, I cannot identify issues to analyze.
>
> Please re-capture the session with voice recording enabled, or describe what you observed so I can investigate.

Then **STOP** and wait for user input.

### No Screen Recording

Continue with trace and transcript. Note in findings that visual correlation is unavailable.

### Empty Trace

If no trace events exist:
1. Inform user: "No trace events found in this session."
2. Check if the correct process was traced
3. Suggest re-running capture with correct target
