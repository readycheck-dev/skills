---
name: observation-extractor
description: Extracts user-reported issues from voice transcript of an ADA capture session. Reads the full transcript holistically, identifies and structuralizes concerns with full context awareness, cross-checks with keyword scanning, then maps back to trace coordinates.
---
# Extract User Observations

## Purpose

Extract user-reported issues from the voice transcript of an ADA capture session. This is the first step in voice-first analysis - the transcript is the ground truth of user observations.

## Context

- **Analysis Session Path**: {{ANALYSIS_SESSION_PATH}}
- **Capture Session**: {{CAPTURE_SESSION}}
- **Output Directory**: {{OUTPUT_DIRECTORY}}
- **ADA Bin Dir**: {{ADA_BIN_DIR}}

## Environment

All `ada` commands must be prefixed with: `export ADA_AGENT_RPATH_SEARCH_PATHS="{{ADA_BIN_DIR}}/../lib"` before execution.

## Step 1. Get Session Time Info

Command: {{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} time-info

Capture `first_event_ns` and `duration_sec` for later calculations.

## Step 2. Get Voice Transcript

REQUIRED: The timeout duration of this tool MUST be 3600000 MS (60 MINUTES)
Command: {{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} transcribe words --format timestamped-text

This returns words with inline timestamps like `[X.XX]word`. Each word's start time is embedded directly in the text.

## Step 3. Read and Understand

Read the full transcript as a continuous narrative. Understand what the user is communicating overall — their major points, the relationships between points, and the overall intent.

**Key change from bottom-up:** Do NOT segment into discourse units. Do NOT scan for keywords. Just read and understand the narrative as a whole.

Produce a **narrative summary** — a free-form understanding of what the user communicated, in natural language. This is your internal comprehension, not a structured output. It captures:

- What major concerns the user raised
- How the concerns relate to each other
- What the user proposed (if anything)
- What was left ambiguous or incomplete in their scrappy oral language

## Step 4. Identify, Structuralize, and Deduplicate Concerns

From the holistic understanding in Step 3, identify distinct concerns. For each concern, structuralize it with the full transcript context, not a local segment. Do not produce duplicate concerns for the same underlying issue expressed in different words.

**Classify the type of each concern** before choosing its field vocabulary:

| Type | Criteria | Examples |
| ---- | -------- | -------- |
| `bug` | Something is broken — wrong behavior, crash, data loss, error state | "it crashes", "wrong value", "doesn't work", "broke after update" |
| `improvement` | Something works but is confusing, awkward, or suboptimal — UX polish, clarity, better feedback | "it's confusing", "doesn't feel right", "hard to tell which mode", "should show X instead" |
| `feature` | Something new that doesn't exist — a capability the user wants added | "we need X", "there should be a way to", "I wish it could" |

**Classification rule**: When the user describes something that *currently exists* but isn't right, it's `bug` or `improvement`. When they describe something that *doesn't exist*, it's `feature`. When the existing thing produces *incorrect output*, it's `bug`. When it produces *correct but confusing/suboptimal output*, it's `improvement`.

**Bug vs Improvement from Unexpected Behavior**: If the user's observation is about *confusion* or *usability* rather than *incorrect output*, classify it as `improvement`.

Each concern produces one issue with:

- `description` — one-sentence summary
- `raw_user_quotes` — exact phrases from transcript supporting this concern (unprocessed)
- `details` — structured decomposition using the style principles and field-name vocabulary below

**Style principles**:

1. **Omit needless words** — strip oral filler, hesitation, repetition
2. **Use definite, specific, concrete language** — replace vague oral phrasing with precise statements
3. **Put statements in positive form** — say what *is*, not what *isn't*
4. **Use the active voice** — direct, clear attribution of actions
5. **Choose a suitable design and stick to it** — pick the right structure for the content
6. **Preserve intent** — do not add information the user didn't express; use `unspecified` for unstated fields

**Field-name vocabulary by issue type:**

For `bug` issues, use field names from QA practice:

- `steps_to_reproduce` — ordered steps from a known starting state
- `expected_result` — what the user expects
- `actual_result` — what actually happens

For `improvement` issues, use field names from usability evaluation:

- `observed_behavior` — factual description of the current state
- `user_difficulty` — why this is suboptimal for the user
- `suggested_improvement` — the user's proposed change

For `feature` issues, use field names from user story format:

- `user_story` — As a [role], I want [goal] so that [benefit]
- `acceptance_criteria` — conditions that define "done"

**Design the structure dynamically:** The field-name vocabulary provides suggested field names, not a rigid schema. Choose the most appropriate structure for each observation's content — a sentence, a list, a nested hierarchy, or any combination that best clarifies the meaning. If the user's observation doesn't fit a field, omit it (`unspecified`). If the content needs a richer structure than a flat string, use one. If a single sentence suffices, use that.

## Step 5. Cross-Check with Keyword Scan

Run keyword scanning against the full transcript as a **verification pass**. This is NOT the primary identification mechanism — the holistic understanding from Steps 3-4 is. The keyword scan is a safety net that catches concerns the holistic reading may have missed.

**Bug Report Keywords:**

You **MUST** be aware of the non-English equivalents to extract from non-English transcripts:

<example>
- "crash", "crashes", "crashed"
- "error", "exception", "failed"
- "broken", "doesn't work", "not working"
- "wrong", "incorrect", "invalid"
- "missing", "disappeared", "lost"
</example>

**Unexpected Behavior Keywords:**

You **MUST** be aware of the non-English equivalents to extract from non-English transcripts:

<example>
- "weird", "strange", "odd"
- "expected X but got Y"
- "should be", "supposed to"
- "slow", "takes too long", "laggy"
- "doesn't respond", "frozen"
</example>

**Improvement Suggestion Keywords:**

You **MUST** be aware of the non-English equivalents to extract from non-English transcripts:

<example>
- "confusing", "unclear", "hard to tell"
- "doesn't feel right", "not intuitive"
- "should be clearer", "would be better if"
- "too many steps", "awkward", "clunky"
- "misleading", "inconsistent"
</example>

**Feature Request Keywords:**

You **MUST** be aware of the non-English equivalents to extract from non-English transcripts:

<example>
- "we need", "there should be a way to"
- "I wish it could", "it would be great if"
- "add a way to", "can we have"
- "it's missing", "no way to" (when referring to absent functionality)
</example>

### Cross-Check Logic

Compare keyword-detected signals with the concerns identified in Step 4:

- **Missed concerns**: If keywords flag a transcript segment that no concern in Step 4 covers, re-read that segment in full context and add the missed concern. This catches quiet observations buried between louder ones.
- **Unsupported concerns**: If a concern from Step 4 has no supporting keyword signal anywhere in its transcript region, re-examine it — the holistic understanding may have over-interpreted.

## Step 6. Classify Severity

For each concern from Steps 4-5, classify severity. Type classification is already done in Step 4 (the type determines which field-name vocabulary was used).

| Severity | Criteria | Examples |
| -------- | -------- | -------- |
| CRITICAL | Data loss, crash, security issue | "crashed and lost my work", "data was deleted" |
| HIGH | Major feature broken | "can't save", "login doesn't work" |
| MEDIUM | Feature degraded but usable | "slow to load", "wrong icon displayed" |
| LOW | Cosmetic, minor annoyance | "button slightly misaligned" |

## Step 7. Anchor to Trace Coordinates

Map each structured concern back to transcript timestamps. This is the mechanical mapping step — no interpretation needed, just connecting understood concerns to time coordinates for trace correlation.

For each issue, identify all anchors in the transcript:

1. Find each distinct sub-point the user makes about this issue
2. For each sub-point, identify the **anchor word** — the first word the user spoke for that sub-point
3. Read the `[X.XX]` prefix of the anchor word as `phenomenon_visible_by`
4. Assign a `role` describing what this anchor represents in context (e.g., `"problem_statement"`, `"elaboration"`, `"proposed_solution"`, `"reproduction_step"`, `"example"`)
5. **Compute `search_start`**:
   - For the **first anchor of the first issue**: `search_start = 0` (session start)
   - For **subsequent anchors**: `search_start = previous_anchor.search_end` (previous anchor in any issue, ordered by time)
   - **Out-of-order exception**: If the user's words indicate the phenomenon predates the previous anchor (e.g., "earlier", "before that", "when I first opened"), extend `search_start` further back
6. Set `search_end` to `phenomenon_visible_by`
7. Keywords for trace filtering come from the user's description at this anchor

A single issue may have multiple **anchors** — distinct moments in the transcript where the user describes a sub-aspect of the same issue. For example:

- A bug report may have anchors for each **reproduction step**
- An improvement may have anchors for the **problem statement** and the **proposed solution**
- A feature request may have anchors for each **capability** the user describes

**Classify `temporal_nature`** at the issue level (not per-anchor):

- `momentary`: a transient event (flicker, flash, crash, freeze, glitch, animation jerk)
- `persistent`: a constant state (wrong color, bad layout, missing element, wrong text)
- `progressive`: a worsening condition (slow, lag, memory growth, degrading performance)

### Early-anchor correction (phenomenon predates recording)

When `phenomenon_visible_by` falls within the **first 5 seconds** of the recording, the user began describing the issue immediately — the phenomenon was already visible before the recording started.

**Correction rule**: If `phenomenon_visible_by < 5.0`:

1. Keep `search_start = 0`.
2. Expand `search_end` by 5 seconds beyond the anchor word.

## Output Format

Write the JSON output to `{{OUTPUT_DIRECTORY}}/user_observations.json` AND return it as your response. Both are required — the file is read by downstream analysis tasks, and the response is used by the orchestrator.

Return a JSON object with this exact structure:

```json
{
  "session_info": {},
  "issues": [
    {
      "id": "ISS-XXX",
      "type": "bug|improvement|feature",
      "severity": "critical|high|medium|low",
      "temporal_nature": "momentary|persistent|progressive",
      "anchors": [
        {
          "phenomenon_visible_by": ${anchor_word_start_sec},
          "search_start": ${search_start},
          "search_end": ${search_end},
          "anchor_word": "${anchor_word}",
          "role": "${role}",
          "keywords": ["${keyword}"]
        }
      ],
      "description": "[issue_description]",
      "raw_user_quotes": [
        "[raw_user_quotes_extracted_from_the_transcript]"
      ],
      "details": {}
    }
  ]
}
```

**MUST:**
The `type` field **MUST** be exactly one of: `bug`, `improvement`, `feature`. Map each detected issue to the correct classification type using the rules in Step 6.

**MUST NOT:**
You **MUST NOT** use detection category names from Step 5 (e.g., `unexpected_behavior`, `bug_report`, `improvement_suggestion`) as `type` values. Those are search heuristics, not output classifications.

### Field Definitions

| Field | Type | Description |
| ----- | ---- | ----------- |
| `id` | string | Sequential identifier (ISS-001, ISS-002, ...) |
| `type` | enum | `bug` (broken behavior), `improvement` (works but suboptimal), or `feature` (new capability) |
| `severity` | enum | `critical`, `high`, `medium`, or `low` |
| `temporal_nature` | enum | `momentary` (flicker/crash), `persistent` (wrong color/layout), or `progressive` (slow/lag) |
| `anchors` | array | One or more anchor points within this issue's discourse unit |
| `anchors[].phenomenon_visible_by` | float | Anchor word start time — latest moment the phenomenon could have first appeared |
| `anchors[].search_start` | float | Previous anchor's `phenomenon_visible_by`, or 0 for the first anchor |
| `anchors[].search_end` | float | Same as `phenomenon_visible_by` |
| `anchors[].anchor_word` | string | The first word the user spoke for this sub-point |
| `anchors[].role` | string | What this anchor represents (e.g., `"problem_statement"`, `"proposed_solution"`, `"reproduction_step"`) |
| `anchors[].keywords` | array | Terms to search for in trace events around this anchor |
| `description` | string | Concise summary of the issue (one sentence) |
| `raw_user_quotes` | array | Exact phrases from transcript supporting this issue |
| `details` | object | Meaning-clarified decomposition of the user's observation, structured per Step 4 |
| `details.*` | varies | Fields use type-specific vocabulary: bug (`steps_to_reproduce`, `expected_result`, `actual_result`), improvement (`observed_behavior`, `user_difficulty`, `suggested_improvement`), feature (`user_story`, `acceptance_criteria`). Structure within each field varies — may be a string, list, or nested object — whatever best clarifies the meaning. |

## Error Handling

### No Transcript Available

If `transcribe segments` returns empty or fails:

```json
{
  "session_info": {...},
  "issues": [],
  "error": "no_voice_recording",
  "fallback_suggestion": "Analyze using screenshots and trace events only"
}
```

### No Issues Found

If transcript exists but contains no bug reports, improvements, or feature requests:

```json
{
  "session_info": {...},
  "issues": [],
  "note": "Transcript contains no reported issues. Session may be a demonstration or exploration session."
}
```

## Important Notes

1. **Preserve User Observations**: Use their exact words in `raw_user_quotes` - don't paraphrase
2. **Time Window Buffer**: Add 5 seconds before/after the mentioned time to catch setup and aftermath
3. **Keyword Selection**: Extract nouns and verbs that would appear in function/class names
4. **Conservative Classification**: When unsure between severities, choose the lower one
5. **One Issue Per Concern**: Each distinct concern (Step 4) produces one issue, which may have multiple anchors within it
6. **No Editorial Commentary**: Do NOT editorialize about whether an issue is a "design proposal" or "not a bug" in your summary text. Classify the `type` field accurately and let the orchestrator handle routing. Your job is extraction and classification, not triage decisions.
