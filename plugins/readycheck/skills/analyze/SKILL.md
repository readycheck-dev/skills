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

## MANDATORY: Recognize Session To Analyze

You **MUST** recognize session to analyze and set **$SESSION** to the session ID.

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

Spawn the `observation-extractor` subagent with the following resolved context.
You **MUST** set `run_in_background` to `false` when spawning this subagent.
You **MUST NOT** set `run_in_background` to `true` when spawning this subagent.
Set **$EXTRACTOR_AGENT_ID** to the returned agent ID.

**CRITICAL:** `$EXTRACTOR_AGENT_ID` is the **agent ID** (hex string like `aa54907fe68efebdb`), NOT the agent name. SendMessage resumption requires the agent ID, not the name.

```
Analysis Session Path: {{$ANALYSIS_SESSION_PATH}}
Capture Session: {{$CAPTURE_SESSION}}
Output Directory: {{$ANALYSIS_SESSION_PATH}}
ADA Bin Dir: {{$ADA_BIN_DIR}}
```

**CRITICAL: If Any Issues Found**:

You MUST go to Step 2.5: Review Extracted Observations.

**MUST:**
You **MUST** proceed to Step 2.5: Review Extracted Observations whenever the issues array is non-empty.

**MUST NOT:** 
You **MUST NOT** skip issues based on your own assessment. 
You **MUST NOT** declare "no actionable issues" when the issues array contains entries.

**CRITICAL: If No Issues Found**:

If `issues` array is empty, you MUST inform the user:

> No issues found in the session.
>
> You can ask me to output the transcript and identify potential issues in the texts.

Then **STOP**.

## MANDATORY: Step 2.5. Present Extracted Observations and Resolve Ambiguities

After the observation-extractor completes, present the extracted issues with their full `details` to the user, then resolve any ambiguities before proceeding to filtering.

### 2.5a. Present Issue Details

For each issue in `user_observations.json`, render the `details` field alongside the description. Format adapts to issue type:

**For `bug` issues:**

> **ISS-XXX** (bug, {{severity}}) — {{description}}
>
> User: {{raw_user_quotes}}
>
> - Steps to reproduce: {{details.steps_to_reproduce}}
> - Expected: {{details.expected_result}}
> - Actual: {{details.actual_result}}
>

**For `improvement` issues:**

> **ISS-XXX** (improvement, {{severity}}) — {{description}}
>
> User: {{raw_user_quotes}}
>
> - Current behavior: {{details.observed_behavior}}
> - User difficulty: {{details.user_difficulty}}
> - Suggested improvement: {{details.suggested_improvement}}
>

**For `feature` issues:**

> **ISS-XXX** (feature, {{severity}}) — {{description}}
>
> User: {{raw_user_quotes}}
>
> - User story: {{details.user_story}}
> - Acceptance criteria: {{details.acceptance_criteria}}
>

Omit any field whose value is `unspecified` or missing. Render list-valued fields as bullet sub-lists.

Output the rendered issues as text, then proceed directly to 2.5b.

### 2.5b. Resolve Extraction-Level Ambiguities

Check `user_observations.json` for:
1. Per-issue `ambiguities` arrays (non-empty)
2. Top-level `unattached_ambiguities` array (non-empty)

If no ambiguities exist, proceed to Step 3.

For each ambiguity, present it using **AskUserQuestion**. Ask one question per message.

The orchestrator formulates the question from the structured ambiguity data:

```json
{
  "question": "Regarding {{ambiguity.subject}}:\n\nYou said:\n{{ambiguity.relevant_quotes, each on its own line, quoted}}\n\n{{ambiguity.tension}}\n\nWhich interpretation is correct?",
  "header": "Clarification",
  "multiSelect": false,
  "options": [
    // Derive 2-3 concrete options from the tension field.
    // Each option should be a distinct structural/behavioral alternative.
    // Always include a "Neither / other" option.
  ]
}
```

**Questioning Rules:**

- Ask one question per message. If a topic needs more exploration, break it into multiple questions.
- Prefer multiple choice when the options are concrete and enumerable.
- Ask yourself if the option can clarify the ambiguity. If not, redsign it.
- Use open-ended when the design space is too wide to enumerate.
- Always present with a diagram in ASCII art for the options when the contents would be expressed as a diagram.
- Frame each question with: what the analysis found, what is ambiguous, and what the design implications are for each option.
- Stop when all six categories have been checked for all issues and no further ambiguity remains.

After resolving all ambiguities, resume the observation-extractor subagent to apply the clarifications.

You **MUST** resolve `$EXTRACTOR_AGENT_ID` to the actual agent ID hex string returned from Step 2 before passing it to `to:`.

```
SendMessage(
  to: {{$EXTRACTOR_AGENT_ID}},
  message: """
  The developer clarified the following ambiguities:

  {{for each resolved ambiguity}}
  - {{ambiguity.subject}}: {{user's answer}}
  {{end for}}

  Update user_observations.json at {{$ANALYSIS_SESSION_PATH}}/user_observations.json:
  1. Update each issue's `details` field to reflect the resolved interpretation.
  2. Remove the resolved ambiguities from each issue's `ambiguities` array.
  """
)
```

Inform the user: "I've resumed the observation-extractor subagent in the background to update `user_observations.json` with your clarifications. I'll continue once it finishes."

Wait for the observation-extractor to complete. You will be automatically notified when it finishes. Do NOT use `sleep` or poll — the notification arrives on its own.

Record each resolution in a `$EXTRACTION_CLARIFICATIONS` array following this schema:

```json
[
  {
    "issue_id": "ISS-XXX or null",
    "subject": "[ambiguity subject]",
    "question": "[the question asked]",
    "answer": "[the user's answer]",
    "design_constraint": "[one-sentence actionable constraint derived from the answer]"
  }
]
```

After all ambiguities are resolved, proceed to Step 3.

## MANDATORY: Step 3. Filtering Detected Issues

**Skip rules (auto-include, no AskUserQuestion):**
- All issues are CRITICAL or HIGH severity — analyze all automatically.
- Exactly 0 or 1 non-CRITICAL/non-HIGH issues — auto-include alongside CRITICAL/HIGH issues. AskUserQuestion requires >= 2 selectable options; presenting a single issue causes InputValidationError.

**Only present the picker when there are 2-3 non-CRITICAL/non-HIGH issues.**

**If 2-3 non-CRITICAL/non-HIGH issues:** Present them individually with AskUserQuestion:

```json
{
  "question": "Which issues should we analyze? Critical and high issues will be analyzed automatically.",
  "header": "Issues",
  "multiSelect": true,
  "options": [
    {
      "label": "{{issues[0].issue.id}} ({{issues[0].issue.severity}})",
      "description": "{{issue.type}}: {{issue.description}}\n{{one_key_detail}}"
    },
    {
      "label": "{{issues[1].issue.id}} ({{issues[1].issue.severity}})",
      "description": "{{issue.type}}: {{issue.description}}\n{{one_key_detail}}"
    },
    {
      "label": "{{issues[2].issue.id}} ({{issues[2].issue.severity}})",
      "description": "{{issue.type}}: {{issue.description}}\n{{one_key_detail}}"
    },
    {
      "label": "Analyze all",
      "description": "Include all identified issues"
    }
  ]
}
```

Where `one_key_detail` is:
- Bug: `"Expected: {{details.expected_result}}"` (or `"Actual: {{details.actual_result}}"` if expected is unspecified)
- Improvement: `"Suggestion: {{details.suggested_improvement}}"`
- Feature: `"Story: {{details.user_story}}"`

**If 4 and 4+ non-CRITICAL/non-HIGH issues:** Too many for individual options. Present the full list in the question text and offer a bulk choice:

```json
{
  "question": "Found {{count}} non-CRITICAL/non-HIGH issues:\n{{numbered_list_with_type_and_key_detail}}\nAnalyze all, or specify which to skip?",
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
}
```

Each entry in `numbered_list_with_type_and_key_detail` should include the type and one key detail:
```
1. ISS-001 (MEDIUM, feature) — description
   Story: As a ..., I want ... so that ...
2. ISS-002 (LOW, bug) — description
   Expected: ..., Actual: ...
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

**Resolve and Spawn Procedure:**

This procedure takes a list of issue IDs and spawns the appropriate type-specific analyzer subagent for each one. It is used in Step 4 (initial analysis) and Step 6 (re-investigation).

For EACH issue ID in the target list, **resolve variables** by following the steps listed below.

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

**Spawn the `issue-analyzer` subagent** with the following resolved context.
You **MUST** use `{{issue_id}}` as the `name` for each `issue-analyzer` subagent.
You **MUST** use `{{issue_id}} [{{issue_type}}] {{description}}` for each subagent's title.
You **MUST** spawn all `issue-analyzer` subagents in **ONE** message to run them in parallel.
You **MUST NOT** spawn `issue-analyzer` subagents one-by-one.
You **MUST** set `run_in_background` to `false` when spawning `issue-analyzer` subagents.
You **MUST NOT** set `run_in_background` to `true` when spawning `issue-analyzer` subagents.
Set **$ANALYZER_AGENT_IDS[{{issue_id}}]** to the returned agent ID for each analyzer.

**CRITICAL:** `$ANALYZER_AGENT_IDS` stores **agent IDs** (hex strings like `aa54907fe68efebdb`), NOT agent names. SendMessage resumption requires the agent ID, not the name.

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
  - "Finding"     <- type-specific summary from analysis.json
-->

### Detailed Findings

#### ISS-XXX: [description]

> User: [literal_quotes from user_wants]

**User Intents:** [structured description in details]

**Confirmed Issue:** [user_observation.confirmed_issue]

**Gap:** [gap.summary] (confidence: [confidence], chain depth: [chain_depth], type: [root_cause_type])

**Causal Chain:** [rendered from causal_mechanism.causal_chain]

**Current Behavior:** [from causal_mechanism.source_analysis]

**Preserve:**
- *Modified element:* [from success_criteria.keep.modified_element — properties of the element being changed that must survive]
- *Surrounding:* [from success_criteria.keep.surrounding_context — neighboring elements that must not be disrupted]

**Change:** [from user_wants.success_criteria.fix — list each element, its current_state, and target_state]
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

Write the developer feedback to disk, then resume each target analyzer using **SendMessage** with its agent ID.

You **MUST** resolve `$ANALYZER_AGENT_IDS[{{issue_id}}]` to the actual agent ID hex string returned from Step 4 before passing it to `to:`.

For each issue ID in `$TARGET_ISSUES`:

```
SendMessage(
  to: {{$ANALYZER_AGENT_IDS[{{issue_id}}]}},
  message: """
  The developer confirmed your analysis is accurate but wants you to investigate additional areas: {{developer_feedback}}.

  Extend your analysis at {{OUTPUT_DIRECTORY}}/analysis.json with findings on those areas. Keep your existing findings intact.
  """
)
```

Inform the user: "I've resumed the issue analyzer subagents to investigate the additional areas you mentioned. I'll continue with the updated findings once they finish."

You **MUST** wait for all resumed analyzers to complete. You will be automatically notified when each finishes. Do NOT use `sleep` or poll — the notifications arrive on their own.
Then you **MUST** go back to Step 5 to merge the new findings with existing ones, and repeat Step 6.

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

Resume each target analyzer using **SendMessage** with its agent ID.

You **MUST** resolve `$ANALYZER_AGENT_IDS[{{issue_id}}]` to the actual agent ID hex string returned from Step 4 before passing it to `to:`.

For each issue ID in `$TARGET_ISSUES`:

```
SendMessage(
  to: {{$ANALYZER_AGENT_IDS[{{issue_id}}]}},
  message: """
  The developer says your analysis is inaccurate: {{developer_feedback}}.

  Re-investigate based on this feedback and update your analysis at {{OUTPUT_DIRECTORY}}/analysis.json.
  """
)
```

Inform the user: "I've resumed the issue analyzer subagents to re-investigate based on your corrections. I'll continue with the updated findings once they finish."

Wait for all resumed analyzers to complete. You will be automatically notified when each finishes. Do NOT use `sleep` or poll — the notifications arrive on their own. Then go back to Step 5 to merge the new findings with existing ones, and repeat Step 6.

## MANDATORY: Step 7. Plan

### Enter Plan Mode

You **MUST** call **EnterPlanMode**.

### Learn the Issue Analyses

1. Read all `{{$ANALYSIS_SESSION_PATH}}/issues/{{issue_id}}/analysis.json` files for every analyzed issue.
2. Scan each issue's analysis for the following ambiguity categories. For each ambiguity found, ask the developer ONE question using **AskUserQuestion** before moving to the next.


### Clarify Ambiguities

You **MUST** check each issue against all then ask user questions to clarify the ambiguities.

<ambiguity_lookup_table>
- **Relational**: The user references multiple elements in the purposed fix or design without specifying how they coexist.
  **Where to look:**
  1. `user_wants.literal_quotes` references multiple elements in the purposed fix or design without specifying how they coexist.
  2. `user_wants.description` references multiple elements in the purposed fix or design without specifying how they coexist.
  3. `user_wants.expected_behavior` references multiple elements in the purposed fix or design without specifying how they coexist.

- **Scope**: The fix targets one location but the same pattern exists in multiple places.
  **Where to look:** `gap.site` points to one location but `causal_mechanism.scope.state_mutation_map` shows sibling components with the same pattern.

- **Degree**: The user describes a qualitative desired outcome without quantifying it.
  **Where to look:**
  1. `user_wants.literal_quotes` uses qualitative terms without thresholds.
  2. `user_wants.description` uses qualitative terms without thresholds.
  3. `user_wants.expected_behavior` uses qualitative terms without thresholds.
  4. `gap` has `behavioral_divergence` or performance-related root cause.

- **Criteria**: The user described a measurable outcome without specifying the criteria. These are things a machine could verify — dimensions, counts, thresholds, timing, ordering — but the user left them unspecified.
  **Where to look:** `user_wants` describes a concrete result (e.g., "show a list", "filter the results") but omits the criteria that determine correctness (how many items? sorted by what? filtered by which field?).

- **Preference**: The user described a quality that only a human can judge — visual appearance, interaction feel, layout aesthetics — without stating their preference. These are design choices where reasonable people would disagree.
  **Where to look:** `user_wants` describes a desired experience (e.g., "make it cleaner", "better layout", "more intuitive") but omits what that looks like in practice. Issue is `feature` or `improvement` with sparse `acceptance_criteria` or `suggested_improvement` in `details`.

- **Lifecycle**: The user mentions state persistence or update frequency without specifying duration, trigger, or reset conditions.
  **Where to look:**
  1. `user_wants.literal_quotes` with persistence/update language.
  2. `user_wants.description` with persistence/update language.
  3. `user_wants.expected_behavior` with persistence/update language.
  4. `causal_mechanism.scope` with lifecycle code (init/deinit/appear/disappear).

- **Priority**: Multiple issues touch the same component with potentially conflicting changes.
  **Where to look:** Cross-issue comparison of `causal_mechanism.scope` — same component appears in multiple issues' scope.
</ambiguity_lookup_table>

You **MUST NOT** present these categories to the user directly.

**Questioning Rules:**

- Ask one question per message. If a topic needs more exploration, break it into multiple questions.
- Prefer multiple choice when the options are concrete and enumerable.
- Ask yourself if the option can clarify the ambiguity. If not, redsign it.
- Use open-ended when the design space is too wide to enumerate.
- Always present with a diagram in ASCII art for the options when the contents would be expressed as a diagram.
- Frame each question with: what the analysis found, what is ambiguous, and what the design implications are for each option.
- Stop when all six categories have been checked for all issues and no further ambiguity remains.

If `$EXTRACTION_CLARIFICATIONS` from Step 2.5 is non-empty, prepend its entries to `$CLARIFICATIONS`. This ensures the plan-designer sees both extraction-level and analysis-level clarifications.

Set `$CLARIFICATIONS` to `null` if no ambiguities were found. Otherwise, set it to an array following this schema:

```json
[
  {
    "issue_id": "ISS-XXX",
    "category": "relational|scope|degree|completeness|lifecycle|priority",
    "ambiguous_source": "[exact text from analysis.json that triggered the ambiguity detection]",
    "source_field": "[analysis.json field path, e.g. user_wants.literal_quotes]",
    "question": "[the question asked to the developer]",
    "answer": "[the developer's verbatim answer]",
    "design_constraint": "[one-sentence actionable constraint derived from the answer, e.g. 'Both sections must be visible simultaneously regardless of selected mode']",
    "options": "[the options of the question asked to the developer]"
  }
]
```

- `ambiguous_source`: the literal text that was ambiguous — so the plan-designer can locate the exact claim.
- `design_constraint`: a normalized, actionable statement that the plan-designer applies directly — no re-interpretation needed.

### Design and Write the Plan

Resolve the following variables:

1. Set `$CAPTURE_SESSION` to the `capture_session_id` field in `{{$ANALYSIS_SESSION_PATH}}/index.json`.
2. Set `$ADA_BIN_DIR` to `${READYCHECK_PLUGIN_ROOT}/bin`.

**Spawn** the `plan-designer` subagent with the following resolved context:

```
Analysis Session Path: {{$ANALYSIS_SESSION_PATH}}
Capture Session: {{$CAPTURE_SESSION}}
Project Source Root: {{$PROJECT_PATH}}
ADA Bin Dir: {{$ADA_BIN_DIR}}
Clarifications: {{$CLARIFICATIONS}}
```

You **MUST** set the name of this subagent to `plan-designer`.
You **MUST** set `run_in_background` to `false` when spawning this subagent.
You **MUST NOT** set `run_in_background` to `true` when spawning this subagent.
Set **$PLAN_DESIGNER_AGENT_ID** to the returned agent ID.

**CRITICAL:** `$PLAN_DESIGNER_AGENT_ID` is the **agent ID** (hex string like `aa54907fe68efebdb`), NOT the name `plan-designer`. SendMessage resumption requires the agent ID, not the name.

Wait for the subagent to complete.

### Handle Plan Result

Read the plan file at `$ANALYSIS_SESSION_PATH/plan.md` and the design checklist at `$ANALYSIS_SESSION_PATH/design-checklist.json`.

**If the plan contains Open Questions (OQ-* entries):**

You **MUST** present the open questions to the developer using **AskUserQuestion**, one at a time. For each question, use the options from the plan.
You **MUST** resolve `$PLAN_DESIGNER_AGENT_ID` to the actual agent ID hex string returned from the plan-designer spawn before passing it to `to:`.
You **MUST** resume the `plan-designer` subagent with the following prompt after collecting all answers:

```
SendMessage(
  to: {{$PLAN_DESIGNER_AGENT_ID}},
  message: """
  The developer answered your open questions:

  OQ-1: [developer's answer]
  OQ-2: [developer's answer]

  Update the plan at `$ANALYSIS_SESSION_PATH/plan.md` and the design checklist at `$ANALYSIS_SESSION_PATH/design-checklist.json` to incorporate these answers.
  """
)
```

Inform the user: "I've resumed the plan-designer subagent in the background to incorporate your answers into the plan. I'll continue once the revised plan is ready."

Wait for the plan-designer to complete. You will be automatically notified when it finishes. Do NOT use `sleep` or poll — the notification arrives on its own. Re-read from `$ANALYSIS_SESSION_PATH/plan.md` and `$ANALYSIS_SESSION_PATH/design-checklist.json`.

**Transfer the plan to the session plan file:**

Call **EnterPlanMode**. Write the plan content into the Claude Code session plan file. Then call **ExitPlanMode**.

#### Plan Content Integrity Rules

When transferring the planner's output to the session plan file, you **MUST NOT**:

1. **MUST NOT summarize** — do not reduce multi-step analysis into bullet points or one-liners.
2. **MUST NOT drop sections** — every section the planner wrote (architecture diagrams, before/after trees, algorithm pseudocode) must appear in the session plan file.
3. **MUST NOT condense** — do not merge separate steps, issues, or design blocks into combined paragraphs.
4. **MUST NOT paraphrase** — do not restate the planner's content in different words. Use the planner's exact wording.
5. **MUST NOT reformat structure** — preserve the planner's heading hierarchy, code blocks, tables, and numbered lists as-is.
6. **MUST NOT inject commentary** — do not add your own summary, introduction, or "remaining changes" wrapper around the plan content.

The plan file produced by the planner is the **single source of truth**. Copy it faithfully.

Once the plan has been approved, you **MUST** execute the plan with the principles in **Execute the Plan**.

### Execute the Plan

You **MUST** analyze the dependencies for each task in the session plan file to execute.
You **MUST** spawn subagents to execute each task.
You **MUST** ask each subagents to mandatorily read the session plan file before it begins its task.
You **MUST NOT** invoke `/readycheck:check` skill once the plan execution completed.

### Handle Plan Rejection

If the user rejects the plan after reviewing it, you must wait for the user's feedback.

After you receive the user's feedback:

You **MUST** resolve `$PLAN_DESIGNER_AGENT_ID` to the actual agent ID hex string returned from the plan-designer spawn before passing it to `to:`.
You **MUST** resume the `plan-designer` subagent with the following prompt:

```
SendMessage(
  to: {{$PLAN_DESIGNER_AGENT_ID}},
  message: """
  The developer rejected the plan: {{$DEVELOPER_FEEDBACK}}.

  Revise the plan at `$ANALYSIS_SESSION_PATH/plan.md` and the design checklist at `$ANALYSIS_SESSION_PATH/design-checklist.json` based on this feedback.
  """
)
```

Inform the user: "I've resumed the plan-designer subagent in the background to revise the plan based on your feedback. I'll continue once the revised plan is ready."

Wait for the plan-designer to complete. You will be automatically notified when it finishes. Do NOT use `sleep` or poll — the notification arrives on its own.

Read the revised plan file from `$ANALYSIS_SESSION_PATH/plan.md` and the design checklist from `$ANALYSIS_SESSION_PATH/design-checklist.json`. The **Plan Content Integrity Rules** above apply identically. Then call **ExitPlanMode** again.

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
