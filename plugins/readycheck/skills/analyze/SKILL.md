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
```

**IMPORTANT**: Always use the full path `${ADA_BIN_DIR}/ada` for commands to avoid conflicts with other `ada` binaries in PATH.
`ensure_release.sh` automatically prefers a valid local `dist/` runtime when the plugin is being tested from a ReadyCheck checkout.

## MANDATORY: Recognize Session To Analyze

You **MUST** recognize session to analyze and set **$SESSION** to the session ID.

To list available sessions:
Command: ${ADA_BIN_DIR}/ada session list

## MANDATORY: Execution Principles

You **MUST** just follow the skill's workflow without using todo or task tool to plan what the next to do.
You **MUST** spawn subagents with `background` set to `false` with the Agent tool.
You **MUST NOT** use the todo or task tool to plan what the next to do.
You **MUST NOT** spawn subagents with `background` set to `true` with the Agent tool.

## MANDATORY: Step 1. Preflight Check

**If $PREFLIGHT_CHECK is set to 1, skip to Step 3.**

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
- Continue to Step 2

## MANDATORY: Step 2. Intialization

**Run session summary to assess trace data quality:**

Command: ${ADA_BIN_DIR}/ada query {{$SESSION}} summary --reading-model sonnet --format json

Parse the JSON output. If `os_info` is present, set **$OS_CATEGORY** to `os_info.category`. Otherwise, set **$OS_CATEGORY** to `"macos"` (default for sessions captured before OS metadata was added).
You **MUST NOT** expose `os_info` and **$OS_CATEGORY** in the response send to the user.

**Create Analysis Session:**

Run:

Command: ${ADA_BIN_DIR}/ada analysis init --capture-session {{$SESSION}} --format json

Parse the JSON output. Set **$ANALYSIS_SESSION_PATH** to the `path` field. Append the `analysis_session_id` to **$DOCTOR_ANALYSIS_SESSIONS** (comma-separated). Append `{{$SESSION}}` to **$DOCTOR_CAPTURE_SESSIONS** (comma-separated).

## MANDATORY: Step 3. Extract User Observations

Resolve the following variables:

1. Set `$CAPTURE_SESSION` to the `capture_session_id` field in `{{$ANALYSIS_SESSION_PATH}}/index.json`.

Spawn the `observation-extractor` subagent with the following resolved context.
You **MUST** set `background` to `false` when spawning this subagent.
You **MUST NOT** set `background` to `true` when spawning this subagent.

```markdown
**ADA Binary Directory**: ${ADA_BIN_DIR}
**Analysis Session Path**: {{$ANALYSIS_SESSION_PATH}}
**Capture Session**: {{$CAPTURE_SESSION}}
**Output Directory**: {{$ANALYSIS_SESSION_PATH}}
```

The observation-extractor returns a minimal JSON response: `{"status": "complete", "issue_count": N, "has_ambiguities": true|false}`. All detail is in `{{$ANALYSIS_SESSION_PATH}}/user_observations.json` on disk.

**CRITICAL: If `issue_count > 0`**:

You MUST go to Step 4: Confirm and Clarify Issues.

**MUST:**

- You **MUST** proceed to Step 4: Confirm and Clarify Issues whenever `issue_count > 0`.

**MUST NOT:**

- You **MUST NOT** skip issues based on your own assessment.
- You **MUST NOT** declare "no actionable issues" when `issue_count > 0`.

**CRITICAL: If `issue_count` is 0**:

You MUST inform the user:

> No issues found in the session.
>
> You can ask me to output the transcript and identify potential issues in the texts.

Then **STOP**.

## MANDATORY: Step 4. Confirm and Clarify Issues

After the observation-extractor completes, present the extracted issues to the user for confirmation and correction, then resolve any ambiguities on the corrected text before proceeding.

### 4.1. Confirm and Select Issues

Read all issues from `{{$ANALYSIS_SESSION_PATH}}/user_observations.json`.

For each issue, you **MUST** render the `details` field alongside the description. Format adapts to issue type:

**For `bug` issues:**

```markdown
**ISS-XXX** (bug, {{severity}}) — {{description}}

> User: {{raw_user_quotes}}

- Steps to reproduce: {{details.steps_to_reproduce}}
- Expected: {{details.expected_result}}
- Actual: {{details.actual_result}}

```

**For `improvement` issues:**

```markdown
**ISS-XXX** (improvement, {{severity}}) — {{description}}

> User: {{raw_user_quotes}}

- Current behavior: {{details.observed_behavior}}
- User difficulty: {{details.user_difficulty}}
- Suggested improvement: {{details.suggested_improvement}}

```

**For `feature` issues:**

```markdown
**ISS-XXX** (feature, {{severity}}) — {{description}}

> User: {{raw_user_quotes}}

- User story: {{details.user_story}}
- Acceptance criteria: {{details.acceptance_criteria}}

```

You **MUST** omit any field whose value is `unspecified` or missing.
You **MUST** render list-valued fields as bullet sub-lists.
You **MUST** output the rendered issues as text, then present the confirmation gate with the `AskUserQuestion` tool.

The `AskUserQuestion` structure adapts to the number of issues.

**If 1 issue:**

```json
{
  "question": "Review the issue above. Confirm to proceed with analysis. To correct any inaccurate text, select \"Type something.\" and describe what needs to be fixed.",
  "header": "Confirm",
  "multiSelect": false,
  "options": [
    {
      "label": "Confirm",
      "description": "The description is accurate. Proceed to analyze this issue."
    },
    {
      "label": "Skip",
      "description": "Do not analyze this issue."
    }
  ]
}
```

- "Confirm" → set `$TARGET_ISSUES` to the issue ID. Proceed to 4.2.
- "Skip" → set `$TARGET_ISSUES` to empty. Proceed to 4.2.
- "Type something." → the user typed corrections. Apply corrections (see **Handling Corrections** below), then re-present.

**If 2 issues:**

```json
{
  "question": "Review the issues above. Select which issues to analyze. To correct any inaccurate text, select \"Type something.\" and describe what needs to be fixed.",
  "header": "Confirm",
  "multiSelect": true,
  "options": [
    {
      "label": "{{issues[0].id}} ({{issues[0].type}}, {{issues[0].severity}})",
      "description": "{{issues[0].description}}\n{{one_key_detail}}"
    },
    {
      "label": "{{issues[1].id}} ({{issues[1].type}}, {{issues[1].severity}})",
      "description": "{{issues[1].description}}\n{{one_key_detail}}"
    }
  ]
}
```

- User selects issues → set `$TARGET_ISSUES` to the selected issue IDs. Proceed to 4.2.
- "Type something." → corrections. Apply corrections, then re-present.

**If 3 issues:**

```json
{
  "question": "Review the issues above. Select which issues to analyze. To correct any inaccurate text, select \"Type something.\" and describe what needs to be fixed.",
  "header": "Confirm",
  "multiSelect": true,
  "options": [
    {
      "label": "{{issues[0].id}} ({{issues[0].type}}, {{issues[0].severity}})",
      "description": "{{issues[0].description}}\n{{one_key_detail}}"
    },
    {
      "label": "{{issues[1].id}} ({{issues[1].type}}, {{issues[1].severity}})",
      "description": "{{issues[1].description}}\n{{one_key_detail}}"
    },
    {
      "label": "{{issues[2].id}} ({{issues[2].type}}, {{issues[2].severity}})",
      "description": "{{issues[2].description}}\n{{one_key_detail}}"
    }
  ]
}
```

3 options + auto "Type something." = 4 (the maximum). Same pattern as 2 issues.

**If 4 and 4+ issues:**

```json
{
  "question": "Review the issues above. Choose how to proceed. To correct any inaccurate text, select \"Type something.\" and describe what needs to be fixed.",
  "header": "Confirm",
  "multiSelect": false,
  "options": [
    {
      "label": "Analyze all",
      "description": "All descriptions are accurate. Analyze every issue."
    },
    {
      "label": "Chat to select",
      "description": "I'd like to discuss which issues to analyze."
    }
  ]
}
```

- "Analyze all" → set `$TARGET_ISSUES` to all issue IDs. Proceed to 4.2.
- "Chat to select" → drop into regular conversation. The user specifies which issues to analyze in their own words. Set `$TARGET_ISSUES` from the user's response. Proceed to 4.2.
- "Type something." → corrections. Apply corrections, then re-present.

Where `one_key_detail` is:

- Bug: `"Expected: {{details.expected_result}}"` (or `"Actual: {{details.actual_result}}"` if expected is unspecified)
- Improvement: `"Suggestion: {{details.suggested_improvement}}"`
- Feature: `"Story: {{details.user_story}}"`

**Handling Corrections:**

When the user selects "Type something." and types corrections:

1. Spawn a subagent to apply the corrections:

```markdown
Agent(
  subagent_type: "general-purpose",
  model: "haiku",
  description: "Apply user corrections to user_observations.json",
  background: false,
  prompt: """
  The user corrected the following in their extracted issues:

  {{for each correction}}
  - Issue {{issue_id}}: {{what the user wants changed}}
  {{end for}}

  Update user_observations.json at {{$ANALYSIS_SESSION_PATH}}/user_observations.json:
  1. Apply the corrections to the specified issue(s).
  2. Only modify these fields: severity, short_description, description, focus_elements, details.*.
  3. Do NOT modify: id, discourse_id, type, is_input_event_triggered, temporal_nature, raw_user_quotes, intervals, round_2_intervals.
  """
)
```

2. Wait for the subagent to complete. Do NOT use `sleep` or poll.
3. Re-read `{{$ANALYSIS_SESSION_PATH}}/user_observations.json`, re-render all issues, and present the confirmation gate again (same structure adapted to issue count).
4. In the re-presentation, process the user's response as a confirmation only — do not apply further corrections.

You **MUST** identify if the user's text field response contains issue analysis. If it does, set it to **$USER_ANALYSIS**.

### 4.2. Resolve Extraction-Level Ambiguities

Check `user_observations.json` for:

1. Per-issue `ambiguities` arrays (non-empty)
2. Top-level `unattached_ambiguities` array (non-empty)

If no ambiguities exist, proceed to Step 5.

For each ambiguity, present it using **AskUserQuestion**. Ask one question per message.

The orchestrator formulates the question from the structured ambiguity data:

```json
{
  "question": "Regarding {{ambiguity.subject}}:\n\nYou said:\n{{ambiguity.relevant_quotes, each on its own line, quoted}}\n\n{{ambiguity.tension}}\n\nWhich interpretation is correct?",
  "header": "Clarification",
  "multiSelect": false,
  "options": [
    // **MUST:**
    // - You **MUST** ask yourself if the options suffice the following requirements. If they not, redsign it.
    //   - The options **CAN** resolve the ambiguity.
    //   - The options **MUST** be grounded in best practices for the relevant domain and workflow, while also accounting for the surrounding operational context and the appropriate time horizon for the decision.
    //   - The options **MUST** describe the outcome from the user's perspective.
    // - You **MUST** provide a free-text option (the "Type something." option) for each question so the user can provide a custom response.
    // - You **MUST** frame each question with:
    //   - The analysis findings.
    //   - The remaining ambiguity.
    //   - The design implications of each option.
    // - You **MUST** ensure each option resolves only the ambiguity being asked about.
    //
    // **MUST NOT:**
    // - You **MUST NOT** describe options in technical languages **UNLESS** you can identity the user has relevant technical background (programming language, framework, tech stack) in user observations.
    // - You **MUST NOT** include conclusions about aspects the user already specified or aspects outside the ambiguity's scope in an option's description.
  ]
}
```

**Questions Presentation Rules:**

<QUESTIONS_PRESENTATION_RULES>

**MUST:**

- You **MUST** resolve the dependencies of all the questions, grouping them into batches, asking one batch in a single message.
- Each option's **description** **MUST** describe a user-visible outcome — what the user sees, hears, or experiences. If a direction must be named, describe it as a behavior from the user's perspective, not as a technique from the implementer's perspective.
- You **MUST** pireview options with ASCII diagrams (markdown) whenever the content is inherently structural—such as flows, hierarchies, decision trees, state transitions, spatial layouts, or side-by-side comparisons—and would lose clarity if described only in prose.

**MUST NOT:**

- You **MUST NOT** present the option preview in **question**.
- You **MUST NOT** present options in the **question** field.
- Each option's **description** **MUST NOT** contain:
  - Specific numeric values, durations, thresholds, or units when those values did not appear in the user's input or in an analyzer artifact.
  - Identifiers from the target codebase (type names, enum cases, function or method names, parameter names, file paths).
  - Technique labels that pre-commit to an implementation approach.
- **Exception**: a specific value or identifier MAY appear in an option's **description** if it is quoted verbatim from a file under `{{$ANALYSIS_SESSION_PATH}}/issues/*/` produced by the issue-analyzer. When this exception is used, cite the artifact path inline.

</QUESTIONS_PRESENTATION_RULES>

After resolving all ambiguities, spawn a subagent to apply the clarifications.

```markdown
Agent(
  subagent_type: "general-purpose",
  model: "haiku",
  description: "Apply ambiguity clarifications to user_observations.json",
  background: false,
  prompt: """
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

Inform the user: "I've spawned a subagent to update `user_observations.json` with your clarifications. I'll continue once it finishes."

Wait for the subagent to complete. You will be automatically notified when it finishes. Do NOT use `sleep` or poll — the notification arrives on its own.

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

After all ambiguities are resolved, proceed to Step 5.

## MANDATORY: Step 5. Evidence Witness

### Step 5.1. Read Pre-Computed Intervals

For each issue ID in `$TARGET_ISSUES`:

1. Read the issue entry from `{{$ANALYSIS_SESSION_PATH}}/user_observations.json`.
2. If `issue.focus_elements` is empty (pure non-visual symptom), skip to Step 5.4 for that issue — no witnesses, no aggregation.
  1. Each entry of `issue.focus_elements` is an object `{element, observable}` — forward the whole list verbatim to the spawn record; the witness's narration table will have one column per pair.
3. Read the issue's `intervals` array. Each entry is one spawn record:

   ```json
   {"id": "E-NNN", "witness_tag": "E-NNN", "start_sec": [number: start_sec], "end_sec": [number: end_sec], "start_ns": [number: start_ns], "end_ns": [number: end_ns], "source": "event_triggered|speech_triggered", "is_fused": true|false}
   ```

   You **MUST** forward the `source` tag to the spawn record so the compiled verdict frontmatter can annotate provenance.
   The tag **MUST NOT** be shown to the witness (blinding invariant).

4. For each interval entry, build one spawn record:

     ```pseudo-code
     spawn_record = {
       infrastructure:  ADA_BIN_DIR, CAPTURE_SESSION,
       density_driver:  issue.temporal_nature,
       density_override: "none",
       what_to_observe: issue.focus_elements,
       interval:        { id: interval.id,
                          witness_tag: interval.witness_tag,
                          source: interval.source,
                          start_ns:  interval.start_ns,
                          end_ns:    interval.end_ns,
                          start_sec: interval.start_sec,
                          end_sec:   interval.end_sec },
       frames_dir:      interval.frames_dir,
       output_path:     {{$ANALYSIS_SESSION_PATH}}/issues/{issue.id}/evidence/{interval.witness_tag}.md
     }
     ```

5. If an issue's `intervals` is empty, skip to Step 5.4 for that issue — there is nothing for witnesses to observe.

You **MUST NOT** include `issue.description`, `issue.raw_user_quotes`, `issue.details` fields in the spawn record.
Those carry expected-outcome words that bias the witness (v4 blinding invariant).
Those fields are read later at the verdict compilation stage (Step 5.3.2), which compares the narration to the expected outcome in a text-only context — no images are in that comparison path.

### Step 5.2. Spawn `evidence-witness` Subagents

Spawn one `evidence-witness` Agent call per interval entry — **all in a single message** so they run concurrently.

You **MUST** set `background` to `false` when spawning `evidence-witness` subagents.
You **MUST** spawn all evidence-witness subagents for all target issues in **ONE** message.
You **MUST NOT** spawn evidence-witness subagents one-by-one.

Spawn-prompt template for each call (no symptom-text fields — this is the blinding invariant):

```markdown
**ADA Binary Directory**:    ${ADA_BIN_DIR}
**Capture Session**:         {{$CAPTURE_SESSION}}
**Interval ID**:             {{$INTERVAL_ID}}
**Interval Start (ns)**:     {{$INTERVAL_START_NS}}
**Interval End (ns)**:       {{$INTERVAL_END_NS}}
**Interval Start (sec)**:    {{$INTERVAL_START_SEC}}
**Interval End (sec)**:      {{$INTERVAL_END_SEC}}
**Issue Temporal Nature**:   {{$ISSUE_TEMPORAL_NATURE}}
**Focus Elements**:          {{$ISSUE_FOCUS_ELEMENTS}}
**Density Override**:         {{$DENSITY_OVERRIDE}}
**Frames Directory**:        {{$FRAMES_DIR}}
**Output File**:             {{$ANALYSIS_SESSION_PATH}}/issues/{{$ISSUE_ID}}/evidence/{{$WITNESS_TAG}}.md
```

`{{$FRAMES_DIR}}` is the relative path from the interval's `frames_dir` field. The witness reads pre-extracted frames from `{{$ANALYSIS_SESSION_PATH}}/{{$FRAMES_DIR}}/`.

For Round-1 spawns, set `{{$DENSITY_OVERRIDE}}` to `none`.

Derive each witness's subagent `name` from `{{$WITNESS_TAG}}`:
- `E-001` → `{{$ISSUE_ID}}/Evidence 1`
- `E-001-C1` → `{{$ISSUE_ID}}/Evidence 1 - Chunk 1`
- `E-001-C2` → `{{$ISSUE_ID}}/Evidence 1 - Chunk 2`

### Step 5.3. Compile Verdicts and Write Evidence

After all witnesses complete, the skill compiles verdicts inline and writes the final `witnessed_evidence.md` per issue. No subagent is spawned for verdict compilation.

#### 5.3.2. Compile Verdict Per Interval

For each interval's narration file:

1. Read the narration file. Parse the per-frame table. The column header format is `<element> — <observable>`; parse it to recover which dimension each column records.

2. Read the issue's expected-outcome from `user_observations.json`:
   - Bug: `details.observed_behavior` (array of dimension entries, each with `phenomenon`, `element`, `specific_values`, and optional `temporal_pattern` / `spatial_region` fields).
   - Improvement: `details.observed_behavior` + `details.user_difficulty`.
   - Feature: `details.user_story`.
   - Always include `raw_user_quotes` (joined) as supporting context.

3. Decide `confirmed` through multi-dimension scoring:

   **Pass 1 — Feature Extraction.** For each interval's narration table, extract structured features. Describe only what the narration table shows:
   - `observed_phenomenon`: the class of visual behavior observed (e.g., "color_transient", "persistent_state", "text_change", "no_change")
   - `observed_temporal_pattern`: how the behavior unfolds across frames (e.g., "single_transient", "repeated", "sustained", "progressive")
   - `observed_subject_name`: which UI element is affected, from the column headers
   - `observed_values`: the specific non-baseline values seen (e.g., ["red"], ["Hello, world!"])
   - `observed_spatial_region`: the location of the element

   Frame indices in the narration table are sparse. Before the witness examines frames, an unchanged-frame-removal filter discards visually identical consecutive frames. The device renders at 60 fps, so each frame index increment represents 1/60 of a second (~16.7ms).

   **Pass 2 — Dimension Alignment.** Read `details.observed_behavior` from `user_observations.json`. For each dimension entry, score how closely the extracted feature matches on a scale of 0.0 to 1.0. Score each dimension independently — do not consider other dimensions' scores:

   - `phenomenon` (score 1.0/1.0): Does the extracted `observed_phenomenon` match the dimension's `phenomenon` field?
   - `temporal_pattern` (score 1.0/1.0): Does the extracted `observed_temporal_pattern` match what the dimension implies?
   - `subject_identity` (score 1.0/1.0): Does the extracted `observed_subject_name` match the dimension's `element` field?
   - `specific_values` (score 1.0/1.0): Do the extracted `observed_values` match the dimension's `specific_values` field?
   - `spatial_region` (score 1.0/1.0): Does the extracted `observed_spatial_region` occur in the expected screen region? (Default 1.0 when subject_identity matches.)

   **Pass 3 — Verdict Derivation.** Compute the verdict deterministically:
   
   ```
   composite = 0.40×phenomenon + 0.25×temporal + 0.20×subject
             + 0.10×values + 0.05×spatial

   if phenomenon < 0.50 → verdict = UNRELATED
   if composite ≥ 0.80  → verdict = CONFIRMED
   if composite ≥ 0.50
      AND phenomenon ≥ 0.70
      AND temporal ≥ 0.60
      AND subject ≥ 0.60 → verdict = ASK_USER
   else                  → verdict = UNRELATED
   return verdict
   ```

   You **MUST** design a script to compute the `verdict` deterministically.
   You **MUST NOT** evaluate the `verdict` with the LLM evaluation.

4. When verdict is ASK_USER, use **AskUserQuestion**:

   ```json
   {
     "question": "Is this related to the {phenomenon} you reported?",
     "header": "Evidence",
     "multiSelect": false,
     "options": [
       {
         "label": "Yes, related",
         "description": "This observation matches the symptom I reported."
       },
       {
         "label": "No, unrelated",
         "description": "This is normal behavior, not the symptom."
       }
     ]
   }
   ```

   You **MUST** first prompt the user about the unconfident items in **Dimension Alignment** in plain language before asking the question.
   You **MUST** show the user the path to the screenshot captured at that exact moment, so they can quickly understand what you are referring to.

   If the user answers "Yes, related", set `verdict` = CONFIRMED. If "No, unrelated", set `verdict` = UNRELATED.

5. Ground every decision in specific rows and columns. Cite frame filenames and column names.

6. If `confirmed: true`:
   - Build `matched_frames: [{frame, at_ns, at_sec}, ...]` listing every row consistent with the expected outcome. Set `frame` to the absolute path: `{{$ANALYSIS_SESSION_PATH}}/issues/{{$ISSUE_ID}}/evidence/frames_{{$INTERVAL_ID}}/<filename>`. Copy `at_ns` and `at_sec` verbatim from the narration table.
   - Derive `narrowed_interval`:
     - Momentary: frames at `max(0, first_idx - 2)` to `min(last_idx + 2, len - 1)` around matched rows; their `at_ns`/`at_sec` become the bounds.
     - Persistent/progressive: original interval bounds unchanged.

7. Hold all verdict data in working memory. Do NOT append verdict data to individual narration files.

   Treat a malformed or empty narration file as `confirmed: false`.

#### 5.3.3. Round-2 Fallback

<PREREQUISITE>
For each issue where ALL Round-1 verdicts are `confirmed: false` AND `is_input_event_triggered == true` AND `temporal_nature == "momentary"`:

Do NOT fire Round 2 when `is_input_event_triggered == false`, when `temporal_nature != "momentary"`, or when at least one Round-1 interval confirmed.
</PREREQUISITE>

1. Read the issue's `round_2_intervals` array from `{{$ANALYSIS_SESSION_PATH}}/user_observations.json`.

2. Round-2 engine selection per `focus_elements[i].observable`:
   - `color`: density 1
   - `text content`: density 1
   - Other properties (`visibility`/`position`/`size`/`state`/`shape`/`opacity`/`alignment`/`font weight`): density per temporal_nature table (1/5/10)
   - Mixed properties: pick strictest density (1 wins over 5 wins over 10).

3. Spawn all Round-2 sub-interval `evidence-witness` subagents in ONE message (blinded, `background: false`). Pass each witness:
   - `INTERVAL_ID` and `WITNESS_TAG` from the `round_2_intervals` entry
   - `DENSITY_OVERRIDE`: the density integer computed in step 2
   - All usual context fields (blinding invariants unchanged)
   - Output: `{{$ANALYSIS_SESSION_PATH}}/issues/{{$ISSUE_ID}}/evidence/R2-S{i}.md`

   You **MUST** spawn all Round-2 witnesses in **ONE** message.
   You **MUST** set `background` to `false`.

4. After Round-2 witnesses return, compile their verdicts using the same 3-pass scoring from Step 5.3.2. Concatenate sub-interval narrations (in `start_sec` order) into a single virtual table for scoring.

5. Hold Round-2 verdict data in working memory. Do NOT delete or overwrite Round-1 narration files — they remain for audit.

#### 5.3.4. Aggregate and Write `witnessed_evidence.md`

For each issue in `$TARGET_ISSUES` that has intervals:

1. Determine which round provides the verdicts:
   - If Round 2 ran and confirmed: use Round-2 results only.
   - Otherwise: use Round-1 results.

2. Filter to `confirmed: true` intervals.

3. For each confirmed interval, read its narration file and compose a full per-interval block. Concatenate all confirmed interval blocks into one file. Each block:

   ```markdown
   ---
   interval_id: <interval_id>
   start_ns: <u64, from narration file header>
   end_ns: <u64, from narration file header>
   start_sec: <float, from narration file header>
   end_sec: <float, from narration file header>
   density: <int, from narration file header>
   frame_count_examined: <int, from narration file header>
   focus_elements: <array, from narration file header>
   ---

   ## Per-frame narration

   <copied verbatim from narration file>

   ---
   dimension_scores:
     phenomenon: <float>
     temporal_pattern: <float>
     subject_identity: <float>
     specific_values: <float>
     spatial_region: <float>
   composite: <float>
   confirmed: true
   matched_frames:
     - frame: <absolute path>
       at_ns: <u64, from narration table>
       at_sec: <float, from narration table>
   narrowed_interval:
     start_ns: <u64, derived>
     end_ns: <u64, derived>
     start_sec: <float, derived>
     end_sec: <float, derived>
   ---

   ## Verdict

   <one paragraph citing specific frame filenames from the narration table, explaining why the observations do or do not match the expected outcome. No invented observations.>
   ```

4. Write to `{{$ANALYSIS_SESSION_PATH}}/issues/{issue_id}/witnessed_evidence.md`.

5. If zero confirmed, write stub:
   ```markdown
   ---
   confirmed: false
   dimension_scores:
     phenomenon: <float>
     temporal_pattern: <float>
     subject_identity: <float>
     specific_values: <float>
     spatial_region: <float>
   composite: <float>
   ---
   ```

6. For issues with `focus_elements: []`, write stub:
   ```markdown
   ---
   non_visual: true
   ---
   ```

Do NOT include `confirmed: false` interval content in the aggregated file.

### Step 5.4. Narrow `$TARGET_ISSUES`

Using the verdict data held in working memory from Step 5.4, narrow `$TARGET_ISSUES`:

Remove from `$TARGET_ISSUES` any issue where all intervals have `confirmed == false`.

- Issues with `focus_elements: []` (pure non-visual) **remain** in `$TARGET_ISSUES`. Step 5.3.4 already wrote a `non_visual: true` stub `witnessed_evidence.md` so `$WITNESSED_EVIDENCE_PATH` always resolves to an existing file for Step 6.
- Issues that had intervals but zero confirmed are **dropped** from `$TARGET_ISSUES` and reported in the final summary as "visual evidence did not confirm symptom; not analysed."
- Treat a missing or malformed `witnessed_evidence.md` as `confirmed: false`.

## MANDATORY: Step 6. Analyze

Set **$TARGET_ISSUES** to the issue IDs confirmed in Step 4.1, **narrowed in Step 5.4** to exclude issues whose visual evidence could not be confirmed.

**MUST:**
You **MUST** spawn the type-specific analyzer subagent for every issue in `$TARGET_ISSUES`.
You **MUST** wait for all subagent analyses to complete before proceeding to Step 7.

**MUST NOT:**
You **MUST NOT** attempt to fix, edit, or patch source code directly based on the observation-extractor output.
You **MUST NOT** skip the analyzer subagents because issues appear "simple" or "straightforward."
You **MUST NOT** substitute your own code reading for the trace-based analysis that analyzers perform.

The type-specific analyzers perform feasibility assessment, architectural constraint detection, data pipeline tracing, and pattern discovery that cannot be replicated by reading source code alone. Skipping them produces superficial fixes that chase symptoms rather than addressing root design issues.

Run the **Resolve and Spawn** procedure below for `$TARGET_ISSUES`.

**Resolve and Spawn Procedure:**

This procedure takes a list of issue IDs and spawns the appropriate type-specific analyzer subagent for each one. It is used in Step 6 (initial analysis) and Step 8 (re-investigation).

For EACH issue ID in the target list, **resolve variables** by following the steps listed below.

1. Read `{{$ANALYSIS_SESSION_PATH}}/user_observations.json`
2. Identify the issue entry matching the current issue ID
3. Extract all parameters from the matched issue entry:
   - `$issue_id` ← `id`
   - `$issue_type` ← `type`
   - `$description` ← `description`
   - `$temporal_nature` ← `temporal_nature`
   - `$is_input_event_triggered` ← `is_input_event_triggered` (bool)
   - `$raw_user_quotes` ← `raw_user_quotes` (JSON array)
   - `$details` ← `details` (JSON object)
4. Set `$CAPTURE_SESSION` to the `capture_session_id` field in `{{$ANALYSIS_SESSION_PATH}}/index.json`.
5. Set `$OUTPUT_DIRECTORY` to `{{$ANALYSIS_SESSION_PATH}}/issues/{{issue_id}}`
6. Set `$PROJECT_SOURCE_ROOT` to the project source code root.
7. Check for `OUTPUT_DIRECTORY/developer_feedback.json`. If it exists, read it and set `$developer_feedback` to its contents. Otherwise set `$developer_feedback` to `null`.
8. Set `$WITNESSED_EVIDENCE_PATH` to `{{$ANALYSIS_SESSION_PATH}}/issues/{{issue_id}}/witnessed_evidence.md` — the file Step 5 aggregated (or the `non_visual: true` / `confirmed: false` stub). The file always exists for every issue remaining in `$TARGET_ISSUES` after Step 5.4.

**Spawn the `issue-analyzer` subagent** with the following resolved context.
You **MUST** use `{{$issue_id}}` as the `name` for each `issue-analyzer` subagent.
You **MUST** use `{{$issue_id}} [{{$issue_type}}] {{$description}}` for each subagent's title.
You **MUST** spawn all `issue-analyzer` subagents in **ONE** message to run them in parallel.
You **MUST NOT** spawn `issue-analyzer` subagents one-by-one.
You **MUST** set `background` to `false` when spawning `issue-analyzer` subagents.
You **MUST NOT** set `background` to `true` when spawning `issue-analyzer` subagents.

```markdown
**ADA Binary Directory**: ${ADA_BIN_DIR}
**Issue ID**: {{$issue_id}}
**Description**: {{$description}}
**Temporal Nature**: {{$temporal_nature}}
**Is Input Event Triggered**: {{$is_input_event_triggered}}
**Raw User Quotes**: {{$raw_user_quotes}}
**Details**: {{$details}}
**Capture Session**: {{$CAPTURE_SESSION}}
**Analysis Session Path**: {{$ANALYSIS_SESSION_PATH}}
**Output Directory**: {{$OUTPUT_DIRECTORY}}
**Project Source Root**: {{$PROJECT_SOURCE_ROOT}}
**OS Category**: {{$OS_CATEGORY}}
**Witnessed Evidence Path**: {{$WITNESSED_EVIDENCE_PATH}}
**Developer Feedback**: {{$developer_feedback}}
```

You **MUST NOT** show these variables above in response to the user.

**Collect Results**: Wait for all analyses to complete.

## MANDATORY: Step 7. Report

You **MUST** read the analysis results from disk: `{{$ANALYSIS_SESSION_PATH}}/issues/{{issue.id}}/analysis.json` for each analyzed issue.
You **MUST** present all analysis results to the user with a markdown block in the following format:

<COMPILED_FINDINGS_FORMAT>

```markdown
## Analysis Summary

### ISS-XXX: [description]

> User: [user_wants.literal_quotes from the issue's analysis.json]

**User Intents:** [user_wants.expected_behavior from the issue's analysis.json]

<!-- Emit one sub-block per entry in analysis.json.failure_patterns, in array order. -->

#### Pattern ISS-XXX-P-1 (intervals: [comma-separated failure_patterns[0].intervals])

**Screenshot:** [![moment](failure_patterns[0].symptom_moments[0].screenshot_in_the_moment)](failure_patterns[0].symptom_moments[0].screenshot_in_the_moment)

**Causal Chain:** [rendered from failure_patterns[0].symptom_moments[0].symptomatic_call_tree]

#### Pattern ISS-XXX-P-2 (intervals: [comma-separated failure_patterns[1].intervals])

**Screenshot:** [![moment](failure_patterns[1].symptom_moments[0].screenshot_in_the_moment)](failure_patterns[0].symptom_moments[0].screenshot_in_the_moment)

**Causal Chain:** [epxlain failure_patterns[1].symptom_moments[0].symptomatic_call_tree in a consice and plain language]

[…same shape as Pattern ISS-XXX-P-1, indexed into failure_patterns[1]…]

<!-- You **MUST NOT** include the section title when there is only ONE pattern found in the issue. The pattern section title **Pattern ISS-XXX-P-1** is ONLY required when there are multiple patterns in an issue. -->
<!-- You **MUST NOT** emit contents other than this template. -->

<!-- Screenshot row rules:
     * When failure_patterns[0].symptom_moments.length == 0, omit the Screenshot row entirely.
     * When length == 1 and symptom_moments[0].screenshot_in_the_moment is non-null,
       render a single image link as shown below.
     * When length >= 2, render a bulleted list — one line per moment, each with its own
       screenshot link and timestamp:
         - Moment 1 (t=12.34s): [![moment](<path>)](<path>)
         - Moment 2 (t=18.91s): [![moment](<path>)](<path>)
     * When every moment has screenshot_in_the_moment == null, omit the Screenshot row. -->

<!-- Causal Chain row rules:
     * Only render for bug-type issues.
     * Read the file at failure_patterns[0].symptom_moments[0].symptomatic_call_tree on demand;
       it is not stored in analysis.json.
     * When that field is null, omit the Causal Chain row. 
     * Describe causal chain in a consice and plain language. -->

```

</COMPILED_FINDINGS_FORMAT>

**Rendering rules:**

- You **MUST** emit the `##### Pattern …` sub-header even for single-pattern issues.
- The **Screenshot** row **MUST** be a markdown image link pointing at `symptom_moments[0].screenshot_in_the_moment`. Follow the `Screenshot row rules` comment above when a pattern has multiple moments.
- You **MUST** omit the **Screenshot** row when every moment's `screenshot_in_the_moment` is null.
- You **MUST** omit the **Visual Transition** row when `visual_transition` is null.
- You **MUST** render the **Causal Chain** row only for bug-type issues. Read the file at `symptom_moments[0].symptomatic_call_tree` on demand. You **MUST NOT** store it in `analysis.json`.

## MANDATORY: Step 8. Developer Review

Present the merged findings from Step 7 and ask the developer to confirm or redirect.

The findings-confirmation gate **MUST** be posed exactly once per session. You **MUST NOT** ask for confirmation of the analyzer's characterization in prose and then follow it with the AskUserQuestion below, or vice versa. Use only the AskUserQuestion defined here.

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

You **MUST** go to Step 9 (Plan).

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

Write the developer feedback to disk, then spawn a subagent for each target issue.

You **MUST** spawn all per-issue `Agent(...)` calls in **ONE** message to run them in parallel.
You **MUST NOT** spawn them one-by-one.
You **MUST** set `background` to `false` for each spawn.

For each issue ID in `$TARGET_ISSUES`:

```markdown
Agent(
  subagent_type: "readycheck:issue-analyzer",
  description: "Investigate additional areas for {{$issue_id}}",
  background: false,
  prompt: """
  The developer confirmed your analysis is accurate but wants you to investigate additional areas: {{$developer_feedback}}.

  Extend your analysis at {{$OUTPUT_DIRECTORY}}/analysis.json with findings on those areas. Keep your existing findings intact.
  """
)
```

Inform the user: "I've spawned fresh subagents to investigate the additional areas you mentioned. I'll continue with the updated findings once they finish."

You **MUST** wait for all spawned subagents to complete. You will be automatically notified when each finishes. Do NOT use `sleep` or poll — the notifications arrive on their own.
Then you **MUST** go back to Step 7 to merge the new findings with existing ones, and repeat Step 8.

**If "Some are inaccurate":**

Prompt the following message to the user:

> Which findings are inaccurate? You can target a specific pattern with `ISS-XXX/P*` (e.g. `ISS-001/P-2`) or leave it issue-wide. Tell me what to look for instead.

Wait for the user's feedback. Extract which issues — and optionally which patterns within an issue — need re-investigation, and the developer's direction for each.

For each issue that needs re-investigation, write the developer's feedback to the issue directory. You **MUST** include `pattern_id` (as the bare `P*` tail, e.g. `"P-2"`) when the developer scoped their critique to a specific pattern. You **MUST** set `pattern_id` to `null` for issue-wide critiques.

```json
// Write to: {{$ANALYSIS_SESSION_PATH}}/issues/{{issue_id}}/developer_feedback.json
{
  "type": "inaccurate",
  "pattern_id": null | "P-2",
  "feedback": "{{$DEVELOPER_FEEDBACK_FOR_THIS_ISSUE}}"
}
```

Set **$TARGET_ISSUES** to the issue IDs the developer flagged as inaccurate (one issue id per entry, regardless of how many patterns within it were flagged).

Spawn a subagent for each target issue.

You **MUST** spawn all per-issue `Agent(...)` calls in **ONE** message to run them in parallel.
You **MUST NOT** spawn them one-by-one.
You **MUST** set `background` to `false` for each spawn.

For each issue ID in `$TARGET_ISSUES`, the `Agent` prompt body **MUST** mirror the written `developer_feedback.json`:

```markdown
Agent(
  subagent_type: "readycheck:issue-analyzer",
  description: "Re-investigate {{$issue_id}} based on developer correction",
  background: false,
  prompt: """
  The developer says your analysis is inaccurate: {{$developer_feedback}}.

  {{#if pattern_id}}Scope: only pattern {{$issue_id}}-{{pattern_id}} is flagged. Leave every other pattern's artifacts intact; re-investigate only the flagged pattern and update its entry in failure_patterns[].{{else}}Scope: issue-wide. Re-investigate every pattern and refresh analysis.json.{{/if}}

  Re-investigate based on this feedback and update your analysis at {{$OUTPUT_DIRECTORY}}/analysis.json.
  """
)
```

Inform the user: "I've spawned subagents to re-investigate based on your corrections. I'll continue with the updated findings once they finish."

Wait for all spawned subagents to complete. You will be automatically notified when each finishes. Do NOT use `sleep` or poll — the notifications arrive on their own. Then go back to Step 7 to merge the new findings with existing ones, and repeat Step 8.

## MANDATORY: Step 9. Plan

### Learn the Issue Analyses

1. Read all `{{$ANALYSIS_SESSION_PATH}}/issues/{{issue_id}}/analysis.json` files for every analyzed issue.
2. Scan each issue's analysis for the following ambiguity categories. For each ambiguity found, ask the developer ONE question using **AskUserQuestion** before moving to the next.

### Clarify Ambiguities in Expected Outcomes

You **MUST** check each issue against all then ask user questions to clarify the ambiguities.
You **MUST NOT** present the following lookup table to the user directly.

**Identify Ambiguities:**

<AMBIGUITY_LOOKUP_TABLE>

**Where to look:**: `user_wants.expected_behavior`

**Find The Ambiguities:**:

- **Relational**: The user references multiple elements in their observation or expectation without specifying how they relate.

- **Degree**: The user describes a qualitative desired outcome without quantifying it (without thresholds).

- **Criteria**:
  - The user described a measurable outcome without specifying the criteria. These are things a machine could verify — dimensions, counts, thresholds, timing, ordering — but the user left them unspecified.
  - The user described a concrete result (e.g., "show a list", "filter the results") but omits the criteria that determine correctness (how many items? sorted by what? filtered by which field?).

- **Preference**: The user described a quality that only a human can judge — visual appearance, interaction feel, layout aesthetics — without stating their preference. These are design choices where reasonable people would disagree.

- **Lifecycle**: The user mentions state persistence or update frequency without specifying duration, trigger, or reset conditions.

</AMBIGUITY_LOOKUP_TABLE>

<IMPORTANT_CONTEXT>
You **MUST** suppress ambiguity findings when a best-practice interpretation is available, provided it respects legacy constraints and does not introduce new issues into the system.
You **MUST** spawn Explore subagents to learn the code if you **DO NOT** know this best-practice respects legacy constraints and does not introduce new issues into the system.

Set `$SUPPRESSED_AMBIGUITIES` to `null` if no ambiguities were supressed. Otherwise, set it to an array following this schema:

```json
[
  {
    "issue_id": "ISS-XXX",
    "pattern_id": null | "ISS-XXX-P-MMM",
    "category": "relational|scope|degree|criteria|preference|lifecycle",
    "ambiguous_source": "[exact text from analysis.json that triggered the ambiguity detection]",
    "source_field": "[analysis.json field path, e.g. user_wants.literal_quotes or failure_patterns[1].symptom_moments[0].visual_transition]",
    "ambiguity": "[the ambiguity found among the issues]",
    "intepretation": "[the intepretation of the ambiguity found among the issues]"
  }
]
```

- Set `pattern_id` to the full `ISS-XXX-P-MMM` id when the ambiguity is scoped to a specific failure pattern. Set it to `null` when the ambiguity is issue-wide.
- Extraction-time suppressions inherited from `$EXTRACTION_CLARIFICATIONS` (Step 4) **MUST** carry `pattern_id: null`.

- You **MUST** write `intepretation` as a definition of the ambiguous term only — a dictionary-style interpretation of what the word or phrase refers to in this session's context.
- You **MUST NOT** include an implementation approach, a fix direction, a preferred technique, or any prescription in `intepretation`. Those are the plan-designer's responsibility, downstream of this step.
- You **MUST NOT** pre-commit the plan-designer to a specific UI change, state-machine change, or other implementation path via `intepretation`. The field explains the ambiguity; it does not decide how the plan-designer should act on that meaning.

</IMPORTANT_CONTEXT>

**Questions Presentation Rules:**

<QUESTIONS_PRESENTATION_RULES>

**MUST:**

- You **MUST** resolve the dependencies of all the questions, grouping them into batches, asking one batch in a single message.
- Each option's **description** **MUST** describe a user-visible outcome — what the user sees, hears, or experiences. If a direction must be named, describe it as a behavior from the user's perspective, not as a technique from the implementer's perspective.
- You **MUST** present options with ASCII diagrams whenever the content is inherently structural—such as flows, hierarchies, decision trees, state transitions, spatial layouts, or side-by-side comparisons—and would lose clarity if described only in prose.

**MUST NOT:**

- You **MUST NOT** present ASCII diagrams in **question**.
- You **MUST NOT** present options in **question** field.
- Each option's **description** **MUST NOT** contain:
  - Specific numeric values, durations, thresholds, or units when those values did not appear in the user's input or in an analyzer artifact.
  - Identifiers from the target codebase (type names, enum cases, function or method names, parameter names, file paths).
  - Technique labels that pre-commit to an implementation approach.
- **Exception**: a specific value or identifier MAY appear in an option's **description** if it is quoted verbatim from a file under `{{$ANALYSIS_SESSION_PATH}}/issues/*/` produced by the issue-analyzer. When this exception is used, cite the artifact path inline.

</QUESTIONS_PRESENTATION_RULES>

If `$EXTRACTION_CLARIFICATIONS` from Step 4 is non-empty, prepend its entries to `$CLARIFICATIONS`. This ensures the plan-designer sees both extraction-level and analysis-level clarifications.

Set `$CLARIFICATIONS` to `null` if no ambiguities were found. Otherwise, set it to an array following this schema:

```json
[
  {
    "issue_id": "ISS-XXX",
    "pattern_id": null | "ISS-XXX-P-MMM",
    "category": "relational|scope|degree|criteria|preference|lifecycle",
    "ambiguous_source": "[exact text from analysis.json that triggered the ambiguity detection]",
    "source_field": "[analysis.json field path, e.g. user_wants.literal_quotes or failure_patterns[1].symptom_moments[0].visual_transition]",
    "question": "[the question asked to the developer]",
    "answer": "[the developer's verbatim answer]",
    "design_constraint": "[one-sentence actionable constraint derived from the answer, e.g. 'Both sections must be visible simultaneously regardless of selected mode']",
    "options": "[the options of the question asked to the developer]"
  }
]
```

- `ambiguous_source`: the literal text that was ambiguous — so the plan-designer can locate the exact claim.
- `design_constraint`: a normalized, actionable statement that the plan-designer applies directly — no re-interpretation needed.
- Set `pattern_id` to the full `ISS-XXX-P-MMM` id when the clarification applies to a specific failure pattern. Set it to `null` when the clarification is issue-wide. Extraction-time clarifications inherited from `$EXTRACTION_CLARIFICATIONS` **MUST** carry `pattern_id: null`.

You **MUST NOT*** show `$CLARIFICATIONS` contents in your response to the user.

### Design and Write the Plan

Resolve the following variables:

1. Set `$CAPTURE_SESSION` to the `capture_session_id` field in `{{$ANALYSIS_SESSION_PATH}}/index.json`.
2. You **MUST** spawn the `plan-designer` subagent with the following resolved context.

  ```markdown
  **ADA Binary Directory**: ${ADA_BIN_DIR}
  **Analysis Session Path**: {{$ANALYSIS_SESSION_PATH}}
  **Capture Session**: {{$CAPTURE_SESSION}}
  **Project Source Root**: {{$PROJECT_PATH}}
  **Clarifications**: {{$CLARIFICATIONS}}
  **Supressed Ambiguities** {{$SUPPRESSED_AMBIGUITIES}}
  ```

**MUST NOT:**

1. You **MUST NOT** update the sesison plan file directly to fix these issues.
2. You **MUST NOT** update the sesison plan file with subagents other than `plan-designer` to fix these issues.
3. You **MUST NOT** set `background` to `true` when spawning `plan-designer` subagent.

**MUST:**

1. You **MUST** set the name of this subagent to `plan-designer`.
2. You **MUST** set `background` to `false` when spawning this subagent.

Wait for the subagent to complete.

### Handle Plan Result

The `plan-designer` subagent responds:

```json
{
  "status": "complete",
  "plan_file_path": "{{$ANALYSIS_SESSION_PATH}}/plan.md"
}
```

**Transfer the plan to the session plan file:**

You **MUST** transfer `$ANALYSIS_SESSION_PATH/plan.md` to the Claude Code session plan file with `cp` via Bash, never with the `Write` tool.

<EXTREMELY_IMPORTANT>

Procedure:

1. You **MUST** call `EnterPlanMode`. The system reminder that follows names the session plan file path (e.g. `$HOME/.claude/plans/<slug>.md`). Capture that path.
2. You **MUST** run, in a single **Bash** call, the verbatim command:
   cp "$ANALYSIS_SESSION_PATH/plan.md" "<session plan file path from step 1>"
   Substitute `$ANALYSIS_SESSION_PATH` and the plan file path before issuing the call.
3. You **MUST** call `ExitPlanMode`.

1. You **MUST NOT** use `Write` to perform this transfer.
2. You **MUST NOT** use `Read` followed by `Write`.
3. You **MUST NOT** paraphrase, summarise, or re-format the plan during the copy.

</EXTREMELY_IMPORTANT>

**Plan Content Integrity Rules:**

When transferring the planner's output to the session plan file, you **MUST NOT**:

1. You **MUST NOT summarize** — do not reduce multi-step analysis into bullet points or one-liners.
2. You **MUST NOT drop sections** — every section the planner wrote (architecture diagrams, before/after trees, algorithm pseudocode) must appear in the session plan file.
3. You **MUST NOT condense** — do not merge separate steps, issues, or design blocks into combined paragraphs.
4. You **MUST NOT paraphrase** — do not restate the planner's content in different words. Use the planner's exact wording.
5. You **MUST NOT reformat structure** — preserve the planner's heading hierarchy, code blocks, tables, and numbered lists as-is.
6. You **MUST NOT inject commentary** — do not add your own summary, introduction, or "remaining changes" wrapper around the plan content

The plan file produced by the planner is the **single source of truth**. Copy it faithfully.

Once the plan has been approved, you **MUST** execute the plan with the principles in **Execute the Plan**.

### Execute the Plan

**MUST:**
You **MUST** analyze the dependencies for each task in the session plan file to execute.

**MUST NOT:**
You **MUST NOT** invoke `/readycheck:check` skill after the plan execution completed.
You **MUST NOT** launch a post-fix verification capture session after the plan execution completed.

### Handle Plan Rejection

If the user rejects the plan after reviewing it, you **MUST** wait for the user's feedback. Record it as `$DEVELOPER_FEEDBACK`.

After you receive the feedback:

- You **MUST NOT** reuse the existing `plan-designer` subagent. Its in-memory state carries the exact `$CLARIFICATIONS` and `$SUPPRESSED_AMBIGUITIES` framing the developer just rejected; continuing the same conversation re-anchors on that framing.
- You **MUST NOT** re-spawn `observation-extractor` or `issue-analyzer`. Their outputs are immutable for the current capture session; the developer's feedback concerns planning, not observation or analysis.
- You **MUST** re-enter Step 9 from the top of **Clarify Ambiguities in Expected Outcomes**, using the existing issue-analyzer artefacts (`analysis.json`, `symptom.json`, `symptomatic-call-tree.md`, `view-structure.md`) as unchanged inputs. Re-read each issue's analysis with `$DEVELOPER_FEEDBACK` in mind.
- You **MUST** re-evaluate `$SUPPRESSED_AMBIGUITIES`: any entry whose `resolved_meaning` the developer's feedback contradicts MUST be removed from suppression and either re-opened as an AskUserQuestion to the developer or left as a flagged ambiguity for the plan-designer to surface.
- You **MUST** re-evaluate `$CLARIFICATIONS`: if the developer's feedback reveals a new clarification need, add it.
- You **MUST** spawn a **fresh** `plan-designer` subagent (new agent ID) with the revised `$CLARIFICATIONS`, revised `$SUPPRESSED_AMBIGUITIES`, and `$DEVELOPER_FEEDBACK` in its spawn context. Do not reuse the previous plan-designer's agent ID.

Inform the user: "I've restarted the planning step with your feedback. The analyzer findings are unchanged; only the ambiguity resolution and plan design are re-done."

Wait for the new plan-designer to complete. Read the revised plan from `$ANALYSIS_SESSION_PATH/plan.md` and `$ANALYSIS_SESSION_PATH/plan.json`. The **Plan Content Integrity Rules** above apply identically. Then call **ExitPlanMode** again.

## CRITICAL: Error Handling

### No Session Found

```bash
${ADA_BIN_DIR}/ada query {{$SESSION}} time-info --reading-model sonnet
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
