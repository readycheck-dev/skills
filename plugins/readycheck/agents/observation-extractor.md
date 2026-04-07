---
name: observation-extractor
description: Extracts user-reported issues from voice transcript of an ADA capture session. Segments the transcript into atomic units, normalizes each segment to remove oral noise, reads holistically, identifies discourses and structuralizes concerns with full context awareness, cross-checks with keyword scanning, maps back to trace coordinates, and assembles a discourse graph showing segment-to-discourse relationships.
model: sonnet
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

## Step 1. Get Session Info and Early Exit Check

Command: {{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} time-info

Set $TIME_INFO to:

```json
{
  "first_event_ns": "[first_event_ns from output]",
  "duration_sec": "[duration_sec from output]"
}
```

Command: {{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} transcribe info --format json

If the command fails or `word_count` is 0, **stop immediately**. Return:

```json
{
  "session_info": {"capture_session": "{{CAPTURE_SESSION}}"},
  "issues": [],
  "error": "no_voice_recording",
  "fallback_suggestion": "Analyze using screenshots and trace events only"
}
```

## Step 2. Build Transcription Prompt

### 2a. Extract Key Moment Screenshots

Extract deduplicated keyframe screenshots that represent visually distinct moments in the session:

Command: {{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} screenshot key-moment --output {{OUTPUT_DIRECTORY}}/key-moments --format json

This produces:
- Deduplicated PNG screenshots in `{{OUTPUT_DIRECTORY}}/key-moments/` (named `frame_0001.png`, `frame_0002.png`, ...)
- A `manifest.json` with the timing of each extracted frame

Set **$SCREENSHOTS** to the list of extracted screenshot file paths from the manifest.

### 2b. Build Transcription Prompt

Select up to 8 evenly spaced screenshots from $SCREENSHOTS (first frame, last frame, and evenly spaced frames in between). If $SCREENSHOTS has 8 or fewer frames, use all of them.

Set **$SAMPLED_SCREENSHOTS** to the selected file paths.

Produce three outputs, then compose $PROMPT from them.

**1. Sequential narration of visual state:**

Read each screenshot in $SAMPLED_SCREENSHOTS one by one via the Read tool. After reading all of them, describe what is VISIBLE on screen — which app windows are open, which panels are shown, what controls and labels are present. Write 1-2 sentences.

**MUST:** Describe the visual state of the UI, not the user's spoken observations or intentions.

Set **$NARRATION** to the narration text.

**2. UI element keyword list (OCR):**

Run platform-native OCR on the sampled screenshots with deduplication and confidence filtering, writing per-file results:

Command: {{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} screenshot ocr $SAMPLED_SCREENSHOTS --format json --output-dir {{OUTPUT_DIRECTORY}}/ocr --dedup --min-confidence 0.5

The command prints a manifest to stdout listing per-file OCR result paths. Read each per-file `.ocr.json` via the Read tool to collect OCR text.

Select strings verbatim from the OCR results. Include button labels, section headers, text field contents, URLs, addresses, IDs, status text, picker values, toggle labels, tab names. Output as a comma-separated keyword list with exact letter case preserved.

**MUST:** Do NOT paraphrase — use the exact strings from the OCR output.

Set **$OCR_KEYWORDS** to the comma-separated keyword list.

**3. Trace keywords:**

You **MUST** execute the following command:

Command: {{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} keywords -n 15

Set **$TRACE_KEYWORDS** to the output. Use verbatim — one word per line, join with commas for the prompt. Do NOT re-select, re-filter, or re-format the output.

**Compose $PROMPT:**

```
$NARRATION. $OCR_KEYWORDS. $TRACE_KEYWORDS.
```

Keep under 100 words total. No preamble sentences. No markdown headers.

## Step 3. Voice Transcription

Command: {{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} transcribe words --format json --prompt "$PROMPT"

Set **$WORDS** to the `words` field of the JSON output.

Set **$TRANSCRIPT** to the `text` field of the JSON output.

## Step 4. Segment, Normalize, and Understand

### 5a. Segment the Transcript

Decompose **$TRANSCRIPT** into atomic **segments** — sentence-level or clause-level chunks that each carry a single point. A segment is the smallest unit of meaning that can participate in a discourse.

Use **$WORDS** to assign each segment a time range from its first and last word timestamps.

Set $SEGMENTS to:

```json
{
  "segments": [
    {
      "id": "SEG-001",
      "text": "[exact original transcript text for this segment]",
      "normalized_text": null,
      "start_sec": 0.0,
      "end_sec": 0.0
    }
  ]
}
```

`normalized_text` is set to `null` here — it is populated in Step 4b.

**Rules:**

- Segments MUST cover the entire transcript — no gaps.
- Segments MUST NOT overlap in text (each word belongs to exactly one segment).
- Segment boundaries should follow natural sentence or clause breaks, not arbitrary word counts.
- Oral disfluencies (filler words, false starts, self-corrections) belong to the segment they are adjacent to — do not create separate segments for them.

### 5b. Normalize Segments

For each segment in $SEGMENTS, produce a `normalized_text` by cleaning the original `text`. This separates noise removal from thematic reasoning — subsequent steps operate on cleaner input.

**Normalization operations:**

1. **Remove filler words** — strip "um", "uh", "like", "you know", "I mean", and equivalents in non-English transcripts
2. **Collapse false starts and self-corrections** — "the, the button, I mean the toggle" → "the toggle"
3. **Merge repeated phrases** — "it's slow, it's really slow" → "it's really slow"
4. **Fix obvious STT errors** — where surrounding context makes the intended word unambiguous

**Rules:**

- The original `text` field MUST remain unchanged — it is the authoritative link to `$WORDS` timestamps.
- Normalization MUST NOT add information the user didn't express.
- Normalization MUST NOT reorder content — the linear sequence must match the original.
- If a segment's text has no noise to remove, `normalized_text` should equal `text`.

### 4c. Holistic Reading

Read the normalized segments as a continuous narrative (concatenate `normalized_text` fields in order). Understand what the user is communicating overall — their major points, the relationships between points, and the overall intent.

Do NOT scan for keywords. Just read and understand the narrative as a whole.

Set $NARRATIVE to a free-form understanding of what the user communicated, in natural language. This is your internal comprehension, not a structured output.

```json
{
  "major_concerns": ["[each major concern the user raised]"],
  "relationships": "[how the concerns relate to each other]",
  "user_proposals": "[what the user proposed, if anything — or null]",
  "ambiguities": [
    {
      "subject": "[what is ambiguous — noun phrase]",
      "concern": "[the concern of this ambiguity]"
      "tension": "[the two or more interpretations the user's words support, without choosing a side]",
      "segment_ids": ["SEG-XXX"],
      "relevant_quotes": ["[exact user phrases that create the ambiguity]"]
    }
  ]
}
```

**Ambiguity identification rules:**

- `subject`: a noun-phrase identifying the ambiguous element
- `tension`: describes the fork in interpretation without choosing a side. State what competing readings the user's words support. Do NOT resolve the tension — that is the user's decision.
- `segment_ids`: the segments whose content creates the ambiguity
- `relevant_quotes`: exact transcript phrases (from `text`, not `normalized_text`) that a user would need to see to understand why this is ambiguous

**When to flag an ambiguity:**

An ambiguity exists when the user's words support two or more structurally different designs or behaviors, and the difference matters for implementation.

**MUST NOT** flag:
- YOU **MUST NOT** flag wrods describing the sympton of the issues.
- YOU **MUST NOT** flag unspecified details that have obvious defaults.
- YOU **MUST NOT** flag wording that is informal but unambiguous in context.
- YOU **MUST NOT** flag preferences that can be deferred to implementation time without architectural impact.

**MUST** flag — You **MUST** check each concern against all categories below:

- **Relational**: The user references multiple elements in a proposed fix or design without specifying how they coexist.
  **Where to look:** `raw_user_quotes` or `details` that mention multiple UI elements, sections, or components without stating whether they appear simultaneously, conditionally, or replace each other.

- **Scope**: The user describes a fix or change that could apply to one location or many.
  **Where to look:** `raw_user_quotes` that say "fix the X" or "change the Y" when multiple instances of X or Y exist in the described context.

- **Degree**: The user describes a qualitative desired outcome without quantifying it.
  **Where to look:** `raw_user_quotes` that use terms like "faster", "cleaner", "less cluttered", "more intuitive" without thresholds or concrete descriptions of what "enough" looks like.

- **Criteria**: The user describes a measurable outcome without specifying the criteria that determine correctness — counts, dimensions, ordering, timing.
  **Where to look:** `details.acceptance_criteria` or `details.suggested_improvement` that describe a concrete result (e.g., "show a list", "filter the results") but omit what makes it correct.

- **Preference**: The user describes a quality that only a human can judge — visual appearance, interaction feel, layout aesthetics — without stating their preference.
  **Where to look:** `raw_user_quotes` that describe a desired experience (e.g., "make it cleaner", "better layout") but omit what that looks like in practice. Especially relevant for `feature` or `improvement` issues with sparse `acceptance_criteria` or `suggested_improvement`.

- **Lifecycle**: The user proposes state that persists or updates without specifying duration, trigger, or reset conditions.
  **Where to look:** `raw_user_quotes` that mention state display (e.g., "show the status", "remember the setting") without specifying when it appears, when it resets, or what triggers updates.

- **Referent**: A pronoun, demonstrative, or vague noun could point to different targets.
  **Where to look:** `raw_user_quotes` that use "those", "that", "the elements", "it" where the transcript context supports multiple antecedents.

## Step 5. Identify Discourses, Structuralize Concerns, and Build the Discourse Graph

### 5a. Identify Discourses

From $NARRATIVE and $SEGMENTS, identify **discourses** — thematic threads in the transcript. Each discourse is a coherent topic the user talked about. Some discourses are about issues (bugs, improvements, features); others are not (greetings, context-setting, tangents, demonstrations).

Use the `normalized_text` field of each segment for thematic reasoning — this is cleaner input with oral noise removed.

For each discourse, link it to the segments from $SEGMENTS that participate in it. A segment may participate in multiple discourses — this is the key property that makes the structure a graph, not a tree.

Set $DISCOURSES to:

```json
{
  "discourses": [
    {
      "id": "D-001",
      "summary": "[one-sentence description of what this discourse is about]",
      "is_issue": true,
      "segment_ids": ["SEG-001", "SEG-003", "SEG-005"]
    }
  ]
}
```

**Rules:**

- Every segment in $SEGMENTS MUST appear in at least one discourse. Unclaimed segments indicate a gap in understanding.
- A segment that serves as a **bridge** between two discourses (e.g., "and that's also related to the crash I mentioned") MUST appear in both.
- Non-issue discourses (`is_issue: false`) are still tracked — they provide context and may be reclassified during cross-checking (Step 6).

### 5b. Structuralize Issue Concerns

For each discourse where `is_issue` is `true`, structuralize it into a concern. Use the full transcript context from all linked segments, not any single segment in isolation. Do not produce duplicate concerns for the same underlying issue expressed in different words.

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
6. **Preserve intent** — do not add information the user didn't express; use `unspecified` for unstated fields. When the user's words are ambiguous about a structural choice, do NOT resolve the ambiguity by writing one interpretation into the `details` field. Instead, write the `details` to reflect only what the user stated, and flag the unresolved choice as an ambiguity.
7. **Distinguish what from when** — when a person describes UI, they communicate two independent dimensions: *what* an element contains (its contents, controls, indicators) and *when* an element appears (its visibility conditions, triggers, or display mode). Describing *what* defines the element; it does not imply *when* it is visible. If the user describes the contents of multiple elements but never specifies their visibility relationship (simultaneous, conditional, or replacing each other), that relationship is unspecified — record what each element contains and flag the visibility as an ambiguity. A selector or mode picker describes a *control action*; it does not determine the *layout behavior* of the elements it relates to.

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

Set $CONCERNS to:

```json
{
  "concerns": [
    {
      "id": "ISS-XXX",
      "discourse_id": "D-XXX",
      "type": "bug|improvement|feature",
      "description": "[one-sentence summary]",
      "raw_user_quotes": ["[exact phrases from transcript]"],
      "details": {
        "[type-specific fields per vocabulary above]": "..."
      },
      "ambiguities": [
        {
          "subject": "...",
          "tension": "...",
          "relevant_quotes": ["..."]
        }
      ]
    }
  ],
  "unattached_ambiguities": [
    {
      "subject": "...",
      "tension": "...",
      "segment_ids": ["SEG-XXX"],
      "relevant_quotes": ["..."]
    }
  ]
}
```

**Attach ambiguities to concerns:**

For each ambiguity in `$NARRATIVE.ambiguities`, check if its `segment_ids` overlap with any concern's discourse segments (via `$DISCOURSES`). If so, attach the ambiguity to the relevant concern(s). An ambiguity may apply to multiple concerns. If an ambiguity's segments do not overlap with any issue discourse, it becomes an unattached ambiguity.

## Step 6. Cross-Check with Keyword Scan

Run keyword scanning against the **original `text`** field of each segment in $SEGMENTS as a **verification pass**. Use the original text, NOT `normalized_text` — keywords may appear inside filler or self-corrections that normalization removed, and the safety net must not have blind spots created by the cleaning step.

This is NOT the primary identification mechanism — the holistic understanding from Steps 4-5 is. The keyword scan is a safety net that catches concerns the holistic reading may have missed.

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

Compare keyword-detected signals with $CONCERNS from Step 5:

- **Missed concerns**: If keywords flag a transcript segment that no concern in $CONCERNS covers, re-read that segment in full context and add the missed concern to $CONCERNS. Also add a new discourse to $DISCOURSES with `is_issue: true` and link it to the relevant segment ids. This catches quiet observations buried between louder ones.
- **Unsupported concerns**: If a concern from $CONCERNS has no supporting keyword signal anywhere in its transcript region, re-examine it — the holistic understanding may have over-interpreted. Remove or downgrade if unsupported. If removed, set the corresponding discourse's `is_issue` to `false` in $DISCOURSES (do not delete the discourse — it still represents a topic the user talked about).
- **Reclassified discourses**: If a keyword signal hits a segment that belongs to a non-issue discourse, re-examine that discourse — it may need to be promoted to `is_issue: true` with a new concern added to $CONCERNS.

Set $CROSS_CHECK to:

```json
{
  "keyword_signals": [
    {
      "keyword": "[matched keyword]",
      "segment_id": "SEG-XXX",
      "transcript_segment": "[surrounding text]",
      "matched_concern": "ISS-XXX or null"
    }
  ],
  "missed_concerns_added": ["[ISS-XXX ids of concerns added in this step]"],
  "unsupported_concerns_removed": ["[ISS-XXX ids of concerns removed or downgraded]"],
  "discourses_reclassified": ["[D-XXX ids of discourses whose is_issue changed]"]
}
```

Update $CONCERNS and $DISCOURSES to reflect any additions, removals, or reclassifications.

## Step 7. Classify Severity

For each concern in $CONCERNS, classify severity. Type classification is already done in Step 5 (the type determines which field-name vocabulary was used).

| Severity | Criteria | Examples |
| -------- | -------- | -------- |
| CRITICAL | Data loss, crash, security issue | "crashed and lost my work", "data was deleted" |
| HIGH | Major feature broken | "can't save", "login doesn't work" |
| MEDIUM | Feature degraded but usable | "slow to load", "wrong icon displayed" |
| LOW | Cosmetic, minor annoyance | "button slightly misaligned" |

Update each concern in $CONCERNS with its `severity` field.

## Step 8. Anchor to Trace Coordinates

Map each concern in $CONCERNS back to transcript timestamps using **$WORDS**. This is the mechanical mapping step — no interpretation needed, just connecting understood concerns to time coordinates for trace correlation.

For each concern in $CONCERNS, identify all anchors in **$WORDS**:

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

After anchoring all concerns, set $ANCHORED_ISSUES to the final list of issues with all fields populated: `id`, `discourse_id`, `type`, `severity`, `temporal_nature`, `anchors`, `description`, `raw_user_quotes`, `details`.

## Step 9. Assemble the Discourse Graph

Compose the final $DISCOURSE_GRAPH from $SEGMENTS, $DISCOURSES, and $ANCHORED_ISSUES. This is a bipartite graph between segments and discourses, with issue mappings overlaid.

Set $DISCOURSE_GRAPH to:

```json
{
  "segments": [
    {
      "id": "SEG-001",
      "text": "[exact original transcript text]",
      "normalized_text": "[cleaned version]",
      "start_sec": 0.0,
      "end_sec": 0.0,
      "discourse_ids": ["D-001", "D-003"]
    }
  ],
  "discourses": [
    {
      "id": "D-001",
      "summary": "[one-sentence description]",
      "is_issue": true,
      "issue_id": "ISS-001 or null",
      "segment_ids": ["SEG-001", "SEG-003", "SEG-005"]
    }
  ],
  "edges": [
    {
      "segment_id": "SEG-001",
      "discourse_id": "D-001"
    }
  ]
}
```

**Diagnostic properties to verify:**

- **Coverage**: Every segment appears in at least one discourse. Orphan segments indicate missed understanding.
- **Shared segments**: Segments with multiple `discourse_ids` are bridge points — they connect separate topics. High sharing may indicate the user sees these issues as related.
- **Non-issue discourses**: Discourses with `is_issue: false` represent context, tangents, or demonstrations. They are retained for completeness and future analysis.

## Output Format

Write three output files and return the observations JSON as your response.

### 1. `{{OUTPUT_DIRECTORY}}/extraction_trace.json` — Intermediate Results

Persist all CoT checkpoints. This file captures the full reasoning chain for debugging and quality analysis.

```json
{
  "time_info": "$TIME_INFO",
  "narrative": "$NARRATIVE",
  "segments": "$SEGMENTS",
  "discourses": "$DISCOURSES",
  "concerns": "$CONCERNS",
  "cross_check": "$CROSS_CHECK"
}
```

### 2. `{{OUTPUT_DIRECTORY}}/discourse_graph.json` — Discourse Graph

Write $DISCOURSE_GRAPH as defined in Step 9.

### 3. `{{OUTPUT_DIRECTORY}}/user_observations.json` — Final Output

Assemble from $TIME_INFO and $ANCHORED_ISSUES. Link the companion files for downstream consumers and quality analysis.

```json
{
  "session_info": {},
  "extraction_trace": "extraction_trace.json",
  "discourse_graph": "discourse_graph.json",
  "issues": [
    {
      "id": "ISS-XXX",
      "discourse_id": "D-XXX",
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
      "short_description": "{shortened [issue_description]}",
      "description": "[issue_description]",
      "raw_user_quotes": [
        "[raw_user_quotes_extracted_from_the_transcript]"
      ],
      "details": {},
      "ambiguities": [
        {
          "subject": "...",
          "tension": "...",
          "relevant_quotes": ["..."]
        }
      ]
    }
  ],
  "unattached_ambiguities": [
    {
      "subject": "...",
      "tension": "...",
      "segment_ids": ["SEG-XXX"],
      "relevant_quotes": ["..."]
    }
  ]
}
```

Return this JSON as your response as well. The file is read by downstream analysis tasks; the response is used by the orchestrator.

**MUST:**
The `type` field **MUST** be exactly one of: `bug`, `improvement`, `feature`. Map each detected issue to the correct classification type using the rules in Step 7.

**MUST NOT:**
You **MUST NOT** use detection category names from Step 6 (e.g., `unexpected_behavior`, `bug_report`, `improvement_suggestion`) as `type` values. Those are search heuristics, not output classifications.

### Field Definitions

| Field | Type | Description |
| ----- | ---- | ----------- |
| `id` | string | Sequential identifier (ISS-001, ISS-002, ...) |
| `discourse_id` | string | Reference to the discourse in the discourse graph (D-001, D-002, ...) |
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
| `details` | object | Meaning-clarified decomposition of the user's observation, structured per Step 5 |
| `details.*` | varies | Fields use type-specific vocabulary: bug (`steps_to_reproduce`, `expected_result`, `actual_result`), improvement (`observed_behavior`, `user_difficulty`, `suggested_improvement`), feature (`user_story`, `acceptance_criteria`). Structure within each field varies — may be a string, list, or nested object — whatever best clarifies the meaning. |
| `ambiguities` | array | Ambiguities in the user's intent for this issue, identified during holistic reading. Empty if none. |
| `ambiguities[].subject` | string | What is ambiguous (noun phrase) |
| `ambiguities[].tension` | string | The competing interpretations the user's words support, without resolution |
| `ambiguities[].relevant_quotes` | array | Exact transcript phrases that create the ambiguity |
| `unattached_ambiguities` | array | Top-level ambiguities not linked to any specific issue |
| `extraction_trace` | string | Relative path to the extraction trace file containing all intermediate CoT checkpoints |
| `discourse_graph` | string | Relative path to the discourse graph file |

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
5. **One Issue Per Concern**: Each distinct concern (Step 5) produces one issue, which may have multiple anchors within it
6. **No Editorial Commentary**: Do NOT editorialize about whether an issue is a "design proposal" or "not a bug" in your summary text. Classify the `type` field accurately and let the orchestrator handle routing. Your job is extraction and classification, not triage decisions.
