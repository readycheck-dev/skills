---
name: observation-extractor
description: Extracts user-reported issues from voice transcript of an ADA capture session. Segments the transcript into atomic units, normalizes each segment to remove oral noise, reads holistically, identifies discourses and structuralizes concerns with full context awareness, cross-checks with keyword scanning, maps back to trace coordinates, and assembles a discourse graph showing segment-to-discourse relationships.
model: sonnet
---
# Extract User Observations

## Purpose

Extract user-reported issues from the voice transcript of an ADA capture session. This is the first step in voice-first analysis - the transcript is the ground truth of user observations.

## Context

- **ADA Binary Directory**: {{$ADA_BIN_DIR}}
- **Analysis Session Path**: {{$ANALYSIS_SESSION_PATH}}
- **Capture Session**: {{$CAPTURE_SESSION}}
- **Output Directory**: {{$OUTPUT_DIRECTORY}}

## Execution Principles

**MUST:**
1. You **MUST** process pagination only when the instruction guarded by `<EXTERMELY_IMPORTANT></EXTERMELY_IMPORTANT>` appeared in the outputs of `ada query {{$CAPTURE_SESSION}} [subcommand]` call.

**MUST NOT:**
1. You **MUST NOT** invent redirect to files when it is not asked to.
2. You **MUST NOT** persist JSON variable to the filesystem until it is asked to.
3. You **MUST NOT** assume pagination (instructions guarded by `<EXTERMELY_IMPORTANT></EXTERMELY_IMPORTANT>`) always happen for each `ada query {{$CAPTURE_SESSION}} [subcommand]` call.

## Step 1. Get Session Info and Early Exit Check

Command: ${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} transcribe info --reading-model sonnet --format json --cache-dir {{$ANALYSIS_SESSION_PATH}}/cache

You **MUST** stop and respond the following JSON immediately if the command fails or `word_count` is 0.

```json
{"status": "error", "error": "no_voice_recording", "issue_count": 0, "has_ambiguities": false, "fallback_suggestion": "Analyze using screenshots and trace events only"}
```

Command: ${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} time-info --reading-model sonnet --cache-dir {{$ANALYSIS_SESSION_PATH}}/cache

Set $SESSION_INFO to:

```json
{
  "first_event_ns": "[first_event_ns from output]",
  "duration_sec": "[duration_sec from output]"
}
```

You **MUST** write the contents of `$SESSION_INFO` (a JSON object) to `{{$OUTPUT_DIRECTORY}}/session_info.json`.

Read the capture session's platform from its manifest:

Path: `~/.ada/sessions/{{$CAPTURE_SESSION}}/manifest.json`

Set **$OS_CATEGORY** to the `os_info.category` field of that JSON.

## Step 2. Voice Transcription

Command: ${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} transcribe well-tempered-tokens --reading-model sonnet --cache-dir {{$ANALYSIS_SESSION_PATH}}/cache --format json --output {{$OUTPUT_DIRECTORY}}/key-moments

- You **MUST** read the next page if the output notifies you to read the next page.
- You **MUST** set the complete outputs to the variable **$TRANSCRIBE_TOKENS**. The next page notifications **MUST** not be in **$TRANSCRIBE_TOKENS**.
- You **MUST** set **$TOKENS** to the `tokens` field in **$TRANSCRIBE_TOKENS**.
  - **$TOKENS** is a single time-ordered stream that mixes two kinds of tokens:
    - **Word tokens** (`kind: "word"`): spoken words from the voice transcript, with `start_sec`, `end_sec`, `text`, `confidence`.
    - **Event tokens** (`kind: "event"`): user input actions (mouse, keyboard, scroll) recorded alongside the voice. They carry `start_sec`, an `event` field (e.g. `"mouse_down"`, `"scroll"`, `"key_down"`), and event-specific fields (`button`, `x`, `y`, `dx`, `dy`, `flags`, `window_id`, `keycode`). Treat event tokens as narrated facts — the user's actions on the system, part of the same narrative as their speech.

## Step 3. Segment, Normalize, and Understand

### 3a. Segment the Transcript

Decompose **$TOKENS** into atomic **segments** — sentence-level or clause-level chunks that each carry a single point. A segment is the smallest unit of meaning that can participate in a discourse.

Segmentation runs across mixed tokens.
A segment's `text` is the rendered concatenation of the tokens inside it: every token — word or event — contributes its `text` field verbatim.
Event tokens whose `text` is non-empty carry a structured string of the form `[event="<action>"]`, where `<action>` is a brief description of the user's hardware action pre-computed by `transcribe tokens`. The `[event="` prefix and the `"]` suffix are fixed; only the quoted payload varies across events and platforms.
Some event tokens (`mouse_up`, `key_up`) have empty `text` and contribute nothing to the segment.

Use each token's `start_sec` to assign the segment its time range. For segments containing only event tokens, `start_sec` and `end_sec` both equal the event's `start_sec`.

**Rules:**

- Segments MUST cover the entire $TOKENS stream — no gaps. Every token belongs to exactly one segment.
- Segment boundaries should follow natural sentence or clause breaks in the narrative. A cluster of events tightly spaced in time (a burst of clicks within a short window) may form a single segment describing the sustained action. An isolated event between two sentences is its own segment.
- Oral disfluencies (filler words, false starts, self-corrections) belong to the segment they are adjacent to — do not create separate segments for them.
- Event tokens do not introduce disfluencies — do not treat them as noise or merge them into surrounding segments against the natural narrative flow.

**Event rendering rules:**

- You **MUST** render each event token by inlining its `text` field verbatim into the segment's `text`. Every non-empty event token's `text` has the form `[event="<action>"]`. Do not paraphrase, summarize, translate, or rewrite the action payload.
- You **MUST NOT** invent `[event="…"]` strings beyond what `transcribe tokens` supplied. If an event's `text` field is empty, it contributes nothing to the segment.
- You **MUST** coalesce a tight burst of event tokens with identical `text` into one inline occurrence in the rendered segment text. A burst of N sequential identical `[event="…"]` tokens renders as one copy of that `[event="…"]`. Burst boundaries are gaps in time, a change in the `text` payload, or an intervening word token.
- You **MUST NOT** demote events to parenthetical English notes outside the segment `text` field, summary phrases, or time-range annotations. The inline `[event="…"]` string IS the event's representation in the segment.

Set **$RAW_SEGMENTS** to a JSON array with the following format:

```json
[
  {
    "id": "SEG-001",
    "text": "[rendered concatenation of tokens in this segment]",
    "start_sec": [start_sec],
    "end_sec": [end_sec]
  }
]
```

### 3b. Normalize Segments

For each segment in $RAW_SEGMENTS, produce a `normalized_text` by cleaning the original `text`. This separates noise removal from thematic reasoning — subsequent steps operate on cleaner input.

**Normalization operations:**

1. **Remove filler words** — strip "um", "uh", "like", "you know", "I mean", and equivalents in non-English transcripts
2. **Collapse false starts and self-corrections** — "the, the button, I mean the toggle" → "the toggle"
3. **Merge repeated phrases** — "it's slow, it's really slow" → "it's really slow"
4. **Fix obvious STT errors** — where surrounding context makes the intended word unambiguous

**Rules:**

- The original `text` field MUST remain unchanged — it is the authoritative link to `$TOKENS` timestamps.
- Normalization MUST NOT add information the user didn't express.
- Normalization MUST NOT reorder content — the linear sequence must match the original.
- If a segment's text has no noise to remove, `normalized_text` should equal `text`.
- **Event descriptions pass through unchanged.** The `[event="…"]` strings in a segment's `text` carry no oral noise and are already in canonical form — leave them intact in `normalized_text`.

Set **$SEGMENTS** to a JSON object with the following format:

```json
{
  "segments": [
    {
      "id": "SEG-001",
      "text": "[rendered concatenation of tokens in this segment]",
      "normalized_text": "[normalized_text]",
      "start_sec": [start_sec],
      "end_sec": [end_sec]
    }
  ]
}
```

### 3c. Understand

Read the normalized segments as a continuous narrative (concatenate `normalized_text` fields in order) holisticcally.
Understand what the user is communicating overall — their major points, the relationships between points, and the overall intent.

Do NOT scan for keywords. Just read and understand the narrative as a whole.

Set **$NARRATIVE** to a JSON object with the following format:

```json
{
  "major_concerns": ["[each major concern the user raised]"],
  "relationships": "[how the concerns relate to each other]",
  "user_proposals": "[what the user proposed, if anything — or null]",
  "ambiguities": [
    {
      "category": "relational|scope|degree|criteria|preference|lifecycle|referent",
      "subject": "[what is ambiguous — noun phrase]",
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
- `category`: which ambiguity category triggered this flag — one of: `relational`, `scope`, `degree`, `criteria`, `preference`, `lifecycle`, `referent`. Must match the category from the MUST-flag checklist.
- `segment_ids`: the segments whose content creates the ambiguity
- `relevant_quotes`: exact transcript phrases (from `text`, not `normalized_text`) that a user would need to see to understand why this is ambiguous

**When to flag an ambiguity:**

An ambiguity exists when the user's words support two or more structurally different designs or behaviors, and the difference matters for implementation.

**MUST NOT** flag:

- YOU **MUST NOT** flag words describing the symptom of the issues.
- YOU **MUST NOT** flag the cause or mechanism behind a symptom. The user reports what they observe, not why it happens. Cause investigation requires trace data and source code — it belongs to the issue-analyzer, not the observation-extractor. Never ask the user to explain synchronization behavior, binding architecture, state machine transitions, timing mechanics, or any other implementation detail.
- YOU **MUST NOT** flag the degree, frequency, or duration of a reported symptom. These are measurable properties that trace data and screenshots can quantify — they are not design decisions.
- YOU **MUST NOT** flag unspecified details that have obvious defaults.
- YOU **MUST NOT** flag wording that is informal but unambiguous in context.
- YOU **MUST NOT** flag preferences that can be deferred to implementation time without architectural impact.

**MUST** flag — You **MUST** check each concern against all categories below:

- **Relational**: The user's proposed fix or desired outcome references multiple UI elements without specifying how they coexist.
  **Where to look:** `raw_user_quotes` where the user proposes a fix or describes a desired outcome mentioning multiple UI elements, sections, or components without stating whether they appear simultaneously, conditionally, or replace each other.

- **Scope**: The user's proposed fix or desired outcome could apply to one location or many.
  **Where to look:** `raw_user_quotes` where the user proposes "fix the X" or "change the Y" when multiple instances of X or Y exist in the described context.

- **Degree**: The user's desired outcome uses qualitative language without quantifying what "enough" looks like.
  **Where to look:** `raw_user_quotes` where the user describes a desired outcome using terms like "faster", "cleaner", "less cluttered", "more intuitive" without thresholds. Does NOT apply to symptom reports — "it flickers", "it's slow", "it crashes" describe what is broken, not what the user wants.

- **Criteria**: The user's desired outcome specifies a measurable result without defining the criteria for correctness — counts, dimensions, ordering, timing.
  **Where to look:** `raw_user_quotes` where the user describes a desired result (e.g., "show a list", "filter the results") but omits what makes it correct.

- **Preference**: The user's desired outcome involves a quality that only a human can judge — visual appearance, interaction feel, layout aesthetics — without stating their preference.
  **Where to look:** `raw_user_quotes` where the user describes a desired experience (e.g., "make it cleaner", "better layout") but omits what that looks like in practice.

- **Lifecycle**: The user's proposed fix introduces state that persists or updates without specifying duration, trigger, or reset conditions.
  **Where to look:** `raw_user_quotes` where the user proposes state display (e.g., "show the status", "remember the setting") without specifying when it appears, when it resets, or what triggers updates.

- **Referent**: A pronoun, demonstrative, or vague noun in the user's symptom report or desired outcome could point to different targets.
  **Where to look:** `raw_user_quotes` that use "those", "that", "the elements", "it" where the transcript context supports multiple antecedents and the ambiguity would change the scope of the fix.

## Step 4. Identify Discourses, Structuralize Concerns, and Build the Discourse Graph

### 4a. Identify Discourses

From $SEGMENTS and $NARRATIVE, identify **discourses** — referential clusters in the transcript. A discourse is the set of segments that refer to overlapping entities or to the same process; segments do not need to be contiguous in time.

You **MUST** use the `normalized_text` field of each segment for referential reasoning.

For each discourse, link it to the segments from $SEGMENTS that participate in it.

Set $DISCOURSES to:

```json
{
  "discourses": [
    {
      "id": "D-001",
      "segment_ids": ["SEG-001", "SEG-003", "SEG-005"]
    }
  ]
}
```

**Rules:**

- You **MUST** assign every segment in $SEGMENTS to at least one discourse.
- You **MUST** include a segment that bridges two discourses (a phrase referring back to a prior topic) in both discourses' `segment_ids`.

### 4b. Identify Concerns Holistically

Across the full set of discourses from Step 4a, identify the **concerns** the user expressed. A concern is one actionable user intent (a single bug, improvement, or feature the user wants addressed). One concern may draw on one or more discourses; each discourse contributes to at most one concern, or to none if it is pure context.

You **MUST** determine concerns by reasoning across the full set of discourses, not by inspecting any one discourse in isolation.

You **MUST** apply the following procedure:

1. For each ordered pair of discourses (A, B), decide whether A and B describe parts of the same actionable user intent. Two discourses describe parts of the same intent when (i) one diagnoses a problem and the other proposes a fix for that same problem, (ii) both describe sub-details of the same defect or capability, or (iii) addressing one would necessarily require addressing the other.
2. Group discourses transitively under the same-intent relation. Each group becomes one concern.
3. Discourses that no group contains (pure navigation, demonstration, narration without any report) contribute to no concern.

For each concern, assign:

- `type` — `bug` when no supporting discourse contains a proposal and the supporting content describes incorrect or broken behavior; `improvement` when at least one supporting discourse describes suboptimal behavior on an existing surface (with or without a paired proposal); `feature` only when every supporting discourse describes a wholly new capability with no diagnosis of an existing surface.
- `supporting_discourses` — one entry per contributing discourse, each tagging the discourse's role: `diagnosis` (reports a problem or sub-optimal state), `proposed_fix` (proposes a change addressing such a problem), or `sub_detail` (adds a small related observation).

**Rules:**

- You **MUST NOT** create a concern with zero supporting discourses.
- You **MUST NOT** split one actionable user intent across multiple concerns. Escape hatch: when uncertain whether two discourses describe one intent or two, apply the dependency test — would addressing the content of one necessarily require addressing the content of the other? If yes, one concern; if no, two concerns.
- You **MUST NOT** assign the same discourse to multiple concerns. Escape hatch: if a discourse genuinely supports two distinct intents, attach it to the intent it most directly addresses and capture the secondary connection as an ambiguity on the other concern.

Set $CONCERNS (initial, before structuralization) to:

```json
{
  "concerns": [
    {
      "id": "ISS-XXX",
      "type": "bug|improvement|feature",
      "supporting_discourses": [
        {"discourse_id": "D-XXX", "role": "diagnosis|proposed_fix|sub_detail"}
      ]
    }
  ]
}
```

### 4c. Structuralize Each Concern

For each concern in $CONCERNS, structuralize it into the issue format defined below. Use the union of segments from all the concern's `supporting_discourses` for transcript context.

**Rules:**

- You **MUST** preserve content from every supporting discourse in the concern's structuralization, mapped by role:
  - `diagnosis` segments populate the concern's problem-shape fields (`actual_result` for `bug`; `observed_behavior` and `user_difficulty` for `improvement`).
  - `proposed_fix` segments populate the concern's solution-shape fields (`suggested_improvement` for `improvement`; `acceptance_criteria` and `user_story` for `feature`).
  - `sub_detail` segments extend the relevant fields above with the additional information the user provided.
- You **MUST NOT** drop content from a supporting discourse during structuralization. Escape hatch: when content from a supporting discourse does not fit any type-specific field, record it as an ambiguity entry on the concern with `subject` naming the unmappable content and `tension` describing the field-fit problem.

Each concern produces one issue with:

- `raw_user_quotes` — exact phrases from transcript supporting this concern (unprocessed) along with the suggestions if applicable.
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

Every issue type carries an ordered list of steps that lead from a known starting state to the place where the user made the observation. The field name varies per type but the contents are the same kind of thing — a sequence of actions.

For `bug` issues, use field names from QA practice:

- `steps_to_reproduce` — ordered steps from a known starting state to the buggy behavior. **MUST** follow **Input-event Extraction** to extract input events when generating steps.
- `expected_result` — array of per-element dimensional descriptors representing what the user expects. Each entry:
    - `element` — focus element name
    - `observable` — observable name
    - `phenomenon` — the class of visual behavior expected: `"steady_state"`, `"color_transient"`, `"text_change"`, `"visibility_change"`, `"position_change"`, or `"no_change"`
    - `specific_values` — array of specific expected values (e.g., `["stable color"]`). Use `["unspecified"]` if not stated.
- `actual_result` — array of per-element dimensional descriptors representing what actually happens. Each entry:
    - `element` — focus element name
    - `observable` — observable name
    - `phenomenon` — the class of visual behavior observed: `"color_transient"`, `"persistent_state"`, `"text_change"`, `"visibility_change"`, `"position_change"`, or `"no_change"`
    - `specific_values` — array of specific observed values (e.g., `["green", "orange"]` for colors, `["too fast to read"]` for text). Use `["unspecified"]` if not stated.

For `improvement` issues, use field names from usability evaluation:

- `steps_to_encounter` — ordered steps from a known starting state to the moment the friction is encountered. **MUST** follow **Input-event Extraction** to extract input events when generating steps.
- `observed_behavior` — array of per-element dimensional descriptors representing the current state. Each entry:
    - `element` — focus element name
    - `observable` — observable name
    - `phenomenon` — the class of visual behavior observed: `"steady_state"`, `"color_transient"`, `"text_change"`, `"visibility_change"`, `"position_change"`, or `"no_change"`
    - `specific_values` — array of specific observed values (e.g., `["truncated"]` for text, `["hidden"]` for visibility). Use `["unspecified"]` if not stated.
- `user_difficulty` — array of per-element dimensional descriptors representing why this is suboptimal for the user. Each entry:
    - `element` — focus element name
    - `observable` — observable name
    - `phenomenon` — the class of usability friction: `"confusing_state"`, `"inconsistent_behavior"`, `"excessive_effort"`, `"misleading_feedback"`, or `"no_change"`
    - `specific_values` — array of specific difficulty descriptions (e.g., `["hard to distinguish states"]`). Use `["unspecified"]` if not stated.
- `suggested_improvement` — the user's proposed change

For `feature` issues, use field names that combine steps with user-story format:

- `steps_to_scenario` — ordered steps from a known starting state *into* the scenario where the missing capability would apply. The field describes the navigation path to the scenario, not the scenario itself; `acceptance_criteria` continues to describe the scenario. **MUST** follow **Input-event Extraction** to extract input events when generating steps.
- `user_story` — As a [role], I want [goal] so that [benefit]
- `acceptance_criteria` — array of per-element dimensional descriptors representing the conditions that define "done". Each entry:
    - `element` — focus element name
    - `observable` — observable name
    - `phenomenon` — the class of visual behavior that signals completion: `"steady_state"`, `"color_transient"`, `"text_change"`, `"visibility_change"`, `"position_change"`, or `"no_change"`
    - `specific_values` — array of specific acceptance values (e.g., `["visible"]` for visibility, `["updated label"]` for text). Use `["unspecified"]` if not stated.

**Input-event Extraction (applies to `steps_to_reproduce`, `steps_to_encounter`, and `steps_to_scenario` equally):**

<INPUT_EVENT_EXTRACTION>
When the discourse's segments contain `[event="…"]` strings (rendered by Step 3a from the input-event tokens captured alongside speech), treat each distinct `[event="…"]` occurrence as one user action in the step list:

- You **MUST** include one step for each `[event="…"]` occurrence that appears in the discourse's segments.
- You **MUST** derive that step's text from the quoted action payload, preserving whatever hardware identity the payload carries (which mouse button, which modifier, which key, etc. — whatever the platform's recorder chose to express).
- You **MUST** use terminology natural to a user on this session's target platform specified by `$OS_CATEGORY`.
- You **MUST** omit events that are not part of the issue's discourse (session setup, incidental navigation, unrelated clicks).
- You **MUST NOT** include raw event fields, coordinates, flag bitmasks, keycode integers, or timestamps in the step text. Steps are instructions to reperform an action, not session forensics.
</INPUT_EVENT_EXTRACTION>

**Classify whether the issue is triggered by an input event (`is_input_event_triggered`):**

Decide one question per issue: does the user's narrative attribute the symptom to a preceding input event, directly or after a delay? Apply this procedure:

1. If the issue's discourse segments contain no `[event="…"]` tokens (the user performed no recorded input events during this discourse, or the capture is pre-sidecar legacy), you **MUST** set `is_input_event_triggered: false` and stop — there is no event to anchor on. Test the segments, not the step field: **Input-event Extraction** above forbids raw event syntax in `steps_to_reproduce` / `steps_to_encounter` / `steps_to_scenario`, so the step list is not a valid place to look for the token.
2. Otherwise, pick the pattern that best fits the user's framing of the event–symptom relationship:
   - **Direct** — the symptom is the immediate consequence of an event ("I clicked Save and it crashed"). → `true`
   - **Delayed but causally linked** — an event initiates something, and the symptom appears after a gap the user treats as downstream of that event, with no intervening user action breaking the chain ("I clicked Export, waited a few seconds, then the progress bar froze"). → `true`
   - **Independent** — the symptom is framed in terms of elapsed time, visual state, or app lifecycle, or the user says it happens regardless of actions. Any `[event="…"]` in the discourse is navigation to show the problem, not its cause ("it crashes on startup"; "the layout is wrong"; "it happens even when I don't touch anything"). → `false`
3. If the pattern is genuinely ambiguous — an event precedes the symptom but the user neither frames it as causal nor frames the symptom as ambient — you **MUST** set `is_input_event_triggered: false`.

**Design the structure dynamically:** The field-name vocabulary provides suggested field names, not a rigid schema. Choose the most appropriate structure for each observation's content — a sentence, a list, a nested hierarchy, or any combination that best clarifies the meaning. If the user's observation doesn't fit a field, omit it (`unspecified`). If the content needs a richer structure than a flat string, use one. If a single sentence suffices, use that.

Set $CONCERNS (final, after structuralization) to:

```json
{
  "concerns": [
    {
      "id": "ISS-XXX",
      "type": "bug|improvement|feature",
      "supporting_discourses": [
        {"discourse_id": "D-XXX", "role": "diagnosis|proposed_fix|sub_detail"}
      ],
      "is_input_event_triggered": true,
      "raw_user_quotes": ["[exact phrases from transcript supporting this concern (unprocessed) along with the suggestions if applicable.]"],
      "details": {
        "[type-specific fields per vocabulary above]": "..."
      },
      "ambiguities": [
        {
          "category": "relational|scope|degree|criteria|preference|lifecycle|referent",
          "subject": "...",
          "tension": "...",
          "relevant_quotes": ["..."]
        }
      ]
    }
  ],
  "unattached_ambiguities": [
    {
      "category": "relational|scope|degree|criteria|preference|lifecycle|referent",
      "subject": "...",
      "tension": "...",
      "segment_ids": ["SEG-XXX"],
      "relevant_quotes": ["..."]
    }
  ]
}
```

**Attach ambiguities to concerns:**

For each ambiguity in `$NARRATIVE.ambiguities`, check if its `segment_ids` overlap with the union of segment_ids from any concern's `supporting_discourses` (resolved via `$DISCOURSES`).
If so, attach the ambiguity to the relevant concern(s). An ambiguity may apply to multiple concerns.
If an ambiguity's segments do not overlap with any issue discourse, it becomes an unattached ambiguity.

## Step 5. Cross-Check

### Cross-Check with Keyword Scan

Run keyword scanning against the **original `text`** field of each segment in $SEGMENTS as a **verification pass**. Use the original text, NOT `normalized_text` — keywords may appear inside filler or self-corrections that normalization removed, and the safety net must not have blind spots created by the cleaning step.

This is NOT the primary identification mechanism — the holistic understanding from Steps 3-4 is. The keyword scan is a safety net that catches concerns the holistic reading may have missed.

**Bug Report Keywords:**

You **MUST** be aware of the non-English equivalents to extract from non-English transcripts:

<EXAMPLE_KEYWORDS>

- "crash", "crashes", "crashed"
- "error", "exception", "failed"
- "broken", "doesn't work", "not working"
- "wrong", "incorrect", "invalid"
- "missing", "disappeared", "lost"

</EXAMPLE_KEYWORDS>

**Unexpected Behavior Keywords:**

You **MUST** be aware of the non-English equivalents to extract from non-English transcripts:

<EXAMPLE_KEYWORDS>

- "weird", "strange", "odd"
- "for Z, expected X but got Y"
- "should be", "supposed to"
- "slow", "takes too long", "laggy"
- "doesn't respond", "frozen"

</EXAMPLE_KEYWORDS>

**Improvement Suggestion Keywords:**

You **MUST** be aware of the non-English equivalents to extract from non-English transcripts:

<EXAMPLE_KEYWORDS>

- "confusing", "unclear", "hard to tell"
- "doesn't feel right", "not intuitive"
- "should be clearer", "would be better if"
- "too many steps", "awkward", "clunky"
- "misleading", "inconsistent"

</EXAMPLE_KEYWORDS>

**Feature Request Keywords:**

You **MUST** be aware of the non-English equivalents to extract from non-English transcripts:

<EXAMPLE_KEYWORDS>

- "we need", "there should be a way to"
- "I wish it could", "it would be great if"
- "add a way to", "can we have"
- "it's missing", "no way to" (when referring to absent functionality)

</EXAMPLE_KEYWORDS>

### Cross-Check Logic

Compare keyword-detected signals with $CONCERNS from Step 4:

- **Missed concerns**: If keywords flag a transcript segment that no concern covers, re-read that segment in full context and add the missed concern to $CONCERNS. You **MUST** populate the missed concern's `supporting_discourses` with the existing discourses in $DISCOURSES whose `segment_ids` include the flagged segment, tagging each entry's `role`; you **MUST** add a new discourse to $DISCOURSES only when no existing discourse covers the flagged segment.
- **Unsupported concerns**: If a concern in $CONCERNS has no supporting keyword signal anywhere in the union of its supporting discourses' segments, you **MUST** remove the concern from $CONCERNS. You **MUST NOT** modify $DISCOURSES when removing a concern; the discourses simply revert to contributing to no concern.
- **Newly relevant discourses**: If a keyword signal hits a segment that belongs to a discourse currently referenced by no concern, you **MUST** either attach that discourse to an existing concern's `supporting_discourses` (with an appropriate role) or seed a new concern from it.

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
  "unsupported_concerns_removed": ["[ISS-XXX ids of concerns removed]"],
  "discourses_newly_attached": ["[D-XXX ids of discourses newly attached to a concern in this step]"]
}
```

Update $CONCERNS and $DISCOURSES to reflect any additions, removals, or reclassifications.

Set variable **$UNATTACHED_AMBIGUITIES** to `$CONCERNS.unattached_ambiguities` (the JSON array). If the array is empty, set it to `[]`.
You **MUST** write the contents of `$UNATTACHED_AMBIGUITIES` (a JSON array) to `{{$OUTPUT_DIRECTORY}}/observations/unattached_ambiguities.json`.

## Step 6. Classify Severity

For each concern in $CONCERNS, classify severity. Type classification is already done in Step 4 (the type determines which field-name vocabulary was used).

| Severity | Criteria | Examples |
| -------- | -------- | -------- |
| CRITICAL | Data loss, crash, security issue | "crashed and lost my work", "data was deleted" |
| HIGH | Major feature broken | "can't save", "login doesn't work" |
| MEDIUM | Feature degraded but usable | "slow to load", "wrong icon displayed" |
| LOW | Cosmetic, minor annoyance | "button slightly misaligned" |

Update each concern in $CONCERNS with its `severity` field.

## Step 7. Anchor to Trace Coordinates

Map each concern in $CONCERNS back to transcript timestamps and to the input-event tokens that triggered it. The output of this step is a single time-sorted `anchors[]` array per issue, carrying two kinds of coordinates:

- `kind: "speech"` — the user's narration about the issue. One per distinct sub-point.
- `kind: "input_event"` — a triggering hardware event, when the issue is `is_input_event_triggered`. One per trigger burst.

Downstream, the SKILL orchestrator pairs adjacent `input_event` → `speech` anchors into visual-evidence intervals.

### Pass A — emit speech anchors

For each distinct sub-point the user makes about the issue, find the anchor word timing from **$TOKENS** (filtering for entries with `kind: "word"`):

1. Find the **anchor word** — the first word the user spoke for that sub-point.
2. Look up the matching word token in **$TOKENS** (where `kind` is `"word"` and `text` matches the anchor word). That token's `start_sec` is the anchor's `at_sec`.
3. Assign a `role` describing what this anchor represents: `"problem_statement"`, `"elaboration"`, `"proposed_solution"`, `"reproduction_step"`, `"encounter_step"`, `"scenario_step"`, `"example"`.
5. Keywords for trace filtering come from the user's description at this anchor.
6. Emit:

   ```json
   {
     "kind": "speech",
     "at_sec": <float>,
     "role": "<role>",
     "anchor_word": "<word>",
     "keywords": ["<kw>", ...]
   }
   ```

An issue may have multiple speech anchors — distinct moments in the transcript where the user describes a sub-aspect of the same issue. For example:

- A bug report may have speech anchors for each **reproduction step**.
- An improvement may have speech anchors for the **problem statement** and the **proposed solution**.
- A feature request may have speech anchors for each **capability** the user describes.

### Pass B — emit one input_event anchor per underlying event token (only when `is_input_event_triggered == true`)

For each issue where `is_input_event_triggered == true`, scan the issue's discourse segments for `[event="…"]` tokens. **Emit one `input_event` anchor per underlying event token in `$TOKENS` that appears within the issue's discourse segments.** Do **not** coalesce tokens into per-burst anchors.

Each anchor:

```json
{
  "kind": "input_event",
  "at_sec": <event.start_sec>,
  "role": "trigger",
  "event_kind": "<event.event>",
  "event_text": "<event.text from render_event_brief, e.g. [event=\"left mouse click\"]>"
}
```

A 17-click burst produces 17 anchors in `anchors[]`. Each anchor is one entry; there is no burst-level aggregate anchor.

Note: segmentation-level rendering (Step 3/4a) still coalesces tight bursts of identical `[event="…"]` tokens into a single inline occurrence for readable segment text. That readability rule is **only** about segment `text`. It does **not** apply to the anchor emission here — anchors enumerate each token individually.

**Rules:**

- You **MUST** emit one `input_event` anchor per event token in the issue's discourse segments. You **MUST NOT** merge events into per-burst anchors or emit a single anchor to represent many events.
- You **MUST** sort the anchors by `at_sec` ascending during the Merge-and-sort step below.
- You **MUST** set `role: "trigger"` on every input_event anchor (legacy field name; the downstream `witness-intervals` tool computes the true trigger-vs-pre-trigger classification per speech anchor from the events list, not from the `role` field).

Downstream consumers (SKILL orchestrator, `ada query witness-intervals` tool) rely on per-event granularity to compute per-event forward intervals with next-event clamping. Merging loses this attribution.

### Merge and sort

Combine the speech anchors from Pass A with the input_event anchors from Pass B into a single `anchors[]` array **sorted ascending by `at_sec`**. The sorted order interleaves the two kinds naturally — a trigger precedes its narration.

### Classify `temporal_nature` at the issue level (not per-anchor)

- `momentary`: a transient event (flicker, flash, crash, freeze, glitch, animation jerk).
- `persistent`: a constant state (wrong colour, bad layout, missing element, wrong text).
- `progressive`: a worsening condition (slow, lag, memory growth, degrading performance).

### MUST rules

- You **MUST** emit every anchor with a `kind` field (exactly `"speech"` or `"input_event"`) and an `at_sec` field.
- You **MUST** order `anchors[]` ascending by `at_sec`.
- You **MUST** emit at least one `input_event` anchor with `role: "trigger"` for every issue where `is_input_event_triggered == true`. Use the earliest `[event="…"]` token in the discourse that precedes the corresponding speech anchor as the trigger.

### MUST NOT rules
- You **MUST NOT** emit `phenomenon_visible_by` on speech anchors; use `at_sec`. The value is the same — it's a rename.
- You **MUST NOT** rename a UI control the user named in `raw_user_quotes`. When the user picks a specific control term, the same term must appear verbatim in `description` and `short_description`. Do not generalize it to a category word and do not swap it for a platform synonym.

After Step 8 (which emits `focus_elements`), set $ANCHORED_ISSUES to:

```json
[
  {
    "id": "ISS-XXX",
    "type": "bug|improvement|feature",
    "supporting_discourses": [
      {"discourse_id": "D-XXX", "role": "diagnosis|proposed_fix|sub_detail"}
    ],
    "severity": "critical|high|medium|low",
    "temporal_nature": "momentary|persistent|progressive",
    "is_input_event_triggered": true|false,
    "focus_elements": [
      {"element": "[UI element semantic name]", "observable": "[observable dimension]"}
    ],
    "short_description": "[one-line summary of the issue]",
    "description": "[multi-sentence description of the issue.]",
    "raw_user_quotes": ["[exact phrases from transcript]"],
    "details": {
      "[type-specific fields per Step 6 vocabulary]": "..."
    },
    "ambiguities": [
      {
        "category": "relational|scope|degree|criteria|preference|lifecycle|referent",
        "subject": "[what is ambiguous]",
        "tension": "[the competing interpretations]",
        "relevant_quotes": ["[exact user phrases]"]
      }
    ],
    "anchors": [
      {
        "kind": "speech",
        "at_sec": "[float: start_sec of the matching word token from $TOKENS]",
        "role": "problem_statement|elaboration|proposed_solution|reproduction_step|encounter_step|scenario_step|example",
        "anchor_word": "[the first word of the sub-point]",
        "keywords": ["[trace-filtering keywords from user description]"],
        "windows": [
          {"window_id": "[integer]", "title": "[window title]", "level": "[integer]", "bounds": {"x": "[float]", "y": "[float]", "w": "[float]", "h": "[float]"}, "screen_idx": "[integer]", "alpha": "[float]", "is_key": true|false}
        ]
      },
      {
        "kind": "input_event",
        "at_sec": "[float: event.start_sec from $TOKENS]",
        "role": "trigger",
        "event_kind": "[event type from token: mouse_down|key_down|scroll|...]",
        "event_text": "[event=\"[action description]\"]",
        "windows": [
          {"window_id": "[integer]", "title": "[window title]", "level": "[integer]", "bounds": {"x": "[float]", "y": "[float]", "w": "[float]", "h": "[float]"}, "screen_idx": "[integer]", "alpha": "[float]", "is_key": true|false}
        ]
      }
    ]
  }
]
```

User input events (mouse, keyboard, scroll) already live inside `$TOKENS` and have been carried through segmentation, discourse, and `raw_user_quotes` by this point. Pass B above additionally promotes the triggering events into `anchors[]` so the orchestrator can address them directly.

## Step 8. Extract `focus_elements` for the Witness

The `evidence-witness` subagent receives a narrow Context: time bounds, density driver, and a list of **focus elements** — structured `{element, observable}` pairs telling the witness *which UI element* to describe and *which dimension of it* to record.
The witness's narration table has one column per pair.
It **MUST NOT** receive the expected outcome (colour values, text contents, state adjectives).
The witness's job is pure observation; the orchestrator decides the verdict downstream by comparing the witness's per-observable narration columns to `details.actual_result` / `observed_behavior` / `user_story`.

For each issue, you **MUST** produce a `focus_elements` list of `{element, observable}` objects.

**Schema** (per issue):

```json
"focus_elements": [
  { "element": "OK button", "observable": "icon" },
  { "element": "OK button", "observable": "text content" }
]
```

**Rules for `focus_elements`:**

- You **MUST** identified UI elements in `description`, `raw_user_quotes`, and the relevant `details.*` field that the user references.
- You **MUST** list these identified UI elements in the `focus_elements` list.
- You **MUST** emit `focus_elements: []` (empty array) **only** when the issue has no UI landing place at all.

<UI_LANDING_PLACE_RULES>
- **Landing-place rule (applies to every issue type):** every issue that references an existing UI location has a **landing place** — the on-screen elements where the observation, friction, or requested change is situated. `focus_elements` must point at that landing place regardless of issue type:
- **`bug`**: `focus_elements` point at the existing elements exhibiting the broken behavior.
  - Source: `details.actual_result` entries.
- **`improvement`**: `focus_elements` point at the existing elements whose current state is suboptimal.
  - Source: `details.observed_behavior` entries.
- **`feature`**: `focus_elements` point at the **existing UI location where the new capability would be applied** — the landing place the user navigated to in `steps_to_scenario`.
  - Source: `details.acceptance_criteria` entries, which name the elements and properties the feature would add or change.
</UI_LANDING_PLACE_RULES>

- You **MUST NOT** emit `focus_elements: []` (empty array) just because the issue is a feature/improvement request.
- You **MUST NOT** emit `focus_elements: []` (empty array) when the user's description references any on-screen element where the change would land.

**Rules for `element` of each element in `focus_elements`:**

- You **MUST** set `element` to **semantic kind** what the UI element *is*. It shall be a noun phrase, not what state it's in.
- You **MUST NOT** include property adjectives (colour, size, position, material) inside `element`.
- You **MUST NOT** include state verbs (`flickers`, `jumps`, `changes`, `blinks`, `fades`, `appears`, `disappears`) inside `element`.
- You **MUST NOT** include expected-outcome words (`green`, `orange`, `red`, `wrong`, `correct`, `missing`, `present`, `empty`, `full`, `hidden`, `visible`) inside `element`.

**Rules for `observable` of each element in `focus_elements`:**

- You **MUST** set `observable` to an **observable dimension** of this element that the witness records per frame (e.g. `"color"`, `"text content"`, `"position"`, `"count"`). It names the kind of observation, **not** the observed value.
- You **MUST NOT** include a **value** or **expected outcome** in `observable`. For example, for `"color"`, red, green and white is the value; for `"text content"`, "Hello, world!", "You are welcome" is the value.
- You **MUST** choose an observable the user's description implicitly references.
- You **MAY** emit multiple pairs for the same `element` when the user's description covers more than one dimension — e.g. `[{"element": "Save button", "observable": "position"}, {"element": "Save button", "observable": "count"}]`.
- You **MUST** emit between 1 and 5 total pairs per visual issue. Aggressive counts dilute the witness's attention and provide diminishing returns.

**Recommended Observable Vocabulary:** (not exhaustive — any observable dimension is fine if it doesn't carry a value):

| `observable` | What the witness records in each cell |
| ---------- | --------------------------------------- |
| `color` | the dominant colour of the element |
| `text content` | the literal characters visible on the element |
| `position` | where the element appears on screen (coordinates, or a zone like "top-left quadrant") |
| `visibility` | whether the element is visible, hidden, partially occluded |
| `size` | the element's extent (width, height, or a size category) |
| `shape` | form factor (round, rectangular, irregular) |
| `opacity` | fully opaque, semi-transparent, invisible |
| `alignment` | layout relative to container (left, right, centre, top, bottom) |
| `state` | interactive state, if observable by appearance (e.g. "highlighted", "greyed out") |
| `font weight` | typographic weight (regular, bold, light) |
| `count` | how many distinct instances of this element are visible on screen |

**Examples:**

<RAW_QUOTE_TO_FOCUS_ELEMENTS_EXAMPLES>

**Raw quote:** *"The upload progress ring turns red around 80% and the percentage text jumps too fast to read."*
**Focus elements:**
```json
[
  { "element": "upload progress ring", "observable": "color" },
  { "element": "upload progress percentage text", "observable": "text content" }
]
```
**NOT:** `{"observable": "red"}`, `{"observable": "turns red"}`, `{"observable": "failing"}`, `{"element": "broken progress ring"}`.

**Raw quote:** *"The Save button is too close to Cancel and the layout feels cramped."*
**Focus elements:**
```json
[
  { "element": "Save button", "observable": "position" },
  { "element": "Cancel button", "observable": "position" }
]
```

**Raw quote:** *"The Save button gets cut off when the window is narrow."*
**Focus elements:**
```json
[
  { "element": "Save button", "observable": "position" },
  { "element": "Save button", "observable": "visibility" },
  { "element": "Save button", "observable": "icon" }
]
```

**Raw quote:** *"After 30 seconds it hangs and nothing moves."*
**Focus elements:** `[]`.
**Rationale:** If you know what does "it" refere to, you can fill identified focus elements for that thing. Else, it is ambiguous and leave it empty.

**Raw quote:** *"The sound is crackling."* - (non-visual)
**Focus elements:** `[]`.
**Rationale:** Sound evidence witnessing is not support at the moment.

**Raw quote:** *"I wish the sidebar had a search field so I can filter entries without scrolling."*
**Focus elements:**
 ```json
 [
   { "element": "sidebar", "observable": "visibility" },
   { "element": "sidebar entry list", "observable": "text content" }
 ]
 ```
**Rationale:** the sidebar is the **landing place** — it exists today and is where the search field would be added. The witness observes the sidebar's current state; the orchestrator decides whether the acceptance criteria (a search field) are met.

**Raw quote:** *"The sync service silently drops records when the server is under load."* (non-visual — no UI landing place)
**Focus elements:** `[]`.

</RAW_QUOTE_TO_FOCUS_ELEMENTS_EXAMPLES>

## Step 9. Attach Target-Window Snapshot to Each Anchor

For every anchor emitted in Step 7 (both `kind: "speech"` and `kind: "input_event"`), attach a `windows: [...]` field containing the target-owned windows visible at that anchor's timestamp. This pre-allocates the crop-target decision so the SKILL orchestrator never needs to issue per-interval window queries downstream — it just reads from the anchor.

Collect every anchor's `at_sec` across all issues into a single comma-separated list, preserving the order you intend to zip responses back to (typically issue-by-issue, anchor-by-anchor within each issue). Run the command **once** for the whole batch:

```bash
${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} windows at --reading-model sonnet --cache-dir {{$ANALYSIS_SESSION_PATH}}/cache --at <at1>,<at2>,<at3>,… --format json
```

The command returns an object with a `queries: [...]` array — one entry per `--at` value, in input order. Walk your anchor list and the `queries` array in lockstep: copy `queries[i].windows` into anchor `i`'s `windows` field verbatim. Preserve every field of each entry (`window_id`, `title`, `level`, `level_name`, `bounds`, `screen_idx`, `alpha`, `is_key`).

**MUST rules:**

- You **MUST** issue exactly one `ada query … windows at` invocation per extractor run, batching every anchor's `at_sec` into its `--at` value. Per-anchor invocations are forbidden.
- You **MUST** preserve the anchor-to-query order when zipping responses back: position `i` in the anchor list maps to position `i` in `queries[]`. Duplicate `at_sec` values across anchors produce duplicate `queries[]` entries; attach each to its own anchor.
- You **MUST** attach a `windows` field to every anchor, regardless of `kind`.
- You **MUST** emit `windows: []` (empty array) for every anchor when the command returns `{"status": "no_window_snapshots"}`. This is the signal that the session pre-dates the window-snapshots sidecar; the SKILL reads empty arrays as "no crop available, use full-display frames."
- You **MUST NOT** run `ada query windows list` at this step — the per-anchor `windows at` snapshot is sufficient; the SKILL reconstructs interval-level reasoning by comparing snapshots across paired anchors.
- You **MUST NOT** filter or modify the returned window records. Bias-protection invariants still apply (no focus-element matching here), but the schema preservation is strict.

**Example anchor after attachment:**

```json
{
  "kind": "speech",
  "at_sec": 49.42,
  "role": "reproduction_step",
  "anchor_word": "flickers",
  "keywords": ["connection", "status"],
  "windows": [
    { "window_id": 42, "title": "Settings", "level": 0, "level_name": "normal",
      "bounds": [120, 80, 1040, 720], "screen_idx": 0, "alpha": 1.0, "is_key": true }
  ]
}
```

For input-event anchors, the `windows` snapshot supplies the crop target when a speech anchor's own snapshot has multiple entries (Tier 2 disambiguation in the SKILL). Typically the `is_key` entry of the input-event anchor's snapshot names the window the user was interacting with when they triggered the symptom.

## Step 10. Classify Perception, Symptom, and Pre-Trigger Windows per Issue

The user's word choice encodes the temporal scale of what they observed. `temporal_nature` (`momentary/persistent/progressive`) names the symptom's intrinsic duration; this step classifies the issue into one of four vocabulary classes and emits **three** derived per-issue scalars the SKILL and downstream tools consume:

- `perception_window_sec` — how far **before** a speech anchor the user could plausibly have been observing the symptom. Only used when the issue is **not** input-event-triggered (there's no event to anchor observation start, so the window must cover latency + pattern-accumulation). Human-factors literature: simple visual RT 190–250 ms; cognitive classification 200–500 ms; word selection + articulation 400–700 ms + 200–500 ms; plus pattern-accumulation 1–5 s for flicker / pulse. VSTM retention 15–30 s sets the upper bound.
- `symptom_duration_sec` — how long the symptom is **physically on screen after the trigger event** that most directly caused it. Measures the visibility of one state-transition cycle, not human latency.
- `pre_trigger_event_window_sec` — empirical **forward catch-window for pre-trigger events** (earlier events in a burst that are not the immediate predecessor of any speech anchor). Tighter than `symptom_duration_sec` because confidence that this specific event drove narration is lower; calibrated per class to match typical reported symptoms.

All three come from the same classification pass: pick the issue's vocabulary class once, then read all three values from the matching row.

**Note on the `momentary + is_input_event_triggered` path.** The downstream `ada query witness-intervals` tool applies Shanks-Pearson-Dickinson 1989 causal-attribution constants (2 s strong, 4 s weak) universally on this path — it does not consume `symptom_duration_sec` or `pre_trigger_event_window_sec`. Those two fields are only consumed by the legacy per-trigger algorithm for non-momentary event-triggered issues (persistent / progressive). `perception_window_sec` is still consumed on all paths for speech-backward intervals. Continue emitting all three fields so non-momentary paths and legacy consumers keep working.

For each issue in `$ANCHORED_ISSUES` with `focus_elements != []`, classify its `raw_user_quotes` + `description` into one of five classes and emit the three scalars:

| Vocabulary class | What the user's words describe | `perception_window_sec` (backward; speech, non-event) | `symptom_duration_sec` (forward; trigger event) | `pre_trigger_event_window_sec` (forward; pre-trigger event) |
| ---------------- | ------------------------------ | ----------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------- |
| instantaneous | A single event seen once and narrated immediately — crashes, freezes, snaps, pops up, vanishes | **2.0** | **1.0** | **0.5** |
| flicker | Fast repeated transitions registered as a brief burst — flickers, flashes, jumps between, too fast to read, strobes | **5.0** | **0.5** | **0.5** |
| pulse | Rhythmic on/off over several seconds — blinks, pulses, cycles, keeps going on and off | **10.0** | **2.0** | **1.0** |
| slow | Gradual drift observed over a long interval — gradually, slowly, eventually, after a while, over time | **30.0** | **5.0** | **2.0** |
| persist | A constant state that is always visible and does not change — always, still, remains, stays, keeps being, is just | **0.0** | **5.0** | **2.0** |

**Rules:**

- You **MUST** emit all three fields (`perception_window_sec`, `symptom_duration_sec`, `pre_trigger_event_window_sec`) on every issue whose `focus_elements` is non-empty. Omit all three for purely non-visual issues (`focus_elements: []`).
- You **MUST** pick exactly one vocabulary class per issue, and read all three values from the same row. Do not mix rows.
- You **MUST** pick one class per issue. When multiple classes plausibly apply (e.g. the user says both "jumps" and "gradually"), choose the widest — erring wider makes Round 1 do more work but reduces how often Round 2 has to fire.
- You **MUST** classify by semantic category, not by exact-word match. The "Characteristic words" column lists representative vocabulary, not a required dictionary. If the user describes a brief repeated flash without using the literal word "flicker", this is still the flicker class.
- You **MUST NOT** emit values outside the sets `perception_window_sec ∈ {0.0, 2.0, 5.0, 10.0, 30.0}`, `symptom_duration_sec ∈ {0.5, 1.0, 2.0, 5.0}`, `pre_trigger_event_window_sec ∈ {0.5, 1.0, 2.0}`. If no class maps cleanly, default to **flicker** (the most common cause of missed Round-1 coverage) and record the ambiguity in `ambiguities`.
- You **MUST NOT** use the three fields interchangeably. They measure different things: `perception_window_sec` is human latency + pattern-accumulation (backward from speech); `symptom_duration_sec` is symptom on-screen presence after the trigger event; `pre_trigger_event_window_sec` is a tighter catch-window for pre-trigger events in a burst.

## Step 11. Assemble the Discourse Graph

Compose the final $DISCOURSE_GRAPH from $SEGMENTS, $DISCOURSES, and $ANCHORED_ISSUES. This is a bipartite graph between segments and discourses, with issue mappings overlaid.

### Attach `discourse_time_span` to each issue

For every issue in `$ANCHORED_ISSUES`, compute:

- `discourse_time_span.start_sec = min(segment.start_sec for segment in issue.supporting_segments)`
- `discourse_time_span.end_sec   = max(segment.end_sec   for segment in issue.supporting_segments)`

where `issue.supporting_segments` is the union of segments resolved by walking each entry of `issue.supporting_discourses[*].discourse_id` into the discourse graph and collecting that discourse's `segment_ids` from `$SEGMENTS`.

Attach the result as `issue.discourse_time_span`:

```json
"discourse_time_span": { "start_sec": 42.64, "end_sec": 70.75 }
```

**Rules:**

- You **MUST** emit `discourse_time_span` on every issue in `$ANCHORED_ISSUES`.
- You **MUST** preserve the invariants `start_sec ≤ min(anchor.at_sec)` and `end_sec ≥ max(anchor.at_sec)` — anchors are drawn from the same segments and always fall inside the span.
- You **MUST NOT** widen the span beyond the discourse's own segments. Do not pad it for narration lag or temporal-nature weighting — the SKILL decides any further expansion.

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
      "concerns_supported": [
        {"concern_id": "ISS-001", "role": "diagnosis|proposed_fix|sub_detail"}
      ],
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
- **Context discourses**: Discourses with `concerns_supported: []` represent navigation, demonstration, or narration without any concern attached. They are retained for completeness and future analysis.

You **MUST** sort each issue's `anchors[]` ascending by `at_sec` in `$ANCHORED_ISSUES`. The `$ISSUES` variable is built in the Output Format section below.

## Output Format

Assemble `user_observations.json` with pre-computed evidence intervals.

### Step 12.1. Compute Evidence Intervals

Pass each issue in `$ANCHORED_ISSUES` as positional-grouped flags to `witness-intervals`. Each `--id` starts a new issue group.

Per-issue flags:
- `--id` (required) — the issue's `id`
- `--temporal-nature` (required) — the issue's `temporal_nature`
- `--event-triggered true|false` (required) — the issue's `is_input_event_triggered`
- `--has-focus-elements true|false` (required) — `true` when `focus_elements` is non-empty, `false` otherwise
- `--discourse-start` / `--discourse-end` — include only when `discourse_time_span` is present
- `--perception-window` — include only when `perception_window_sec` is present
- `--symptom-duration` — include only when `symptom_duration_sec` is present
- `--pre-trigger-window` — include only when `pre_trigger_event_window_sec` is present
- `--anchor kind:at_sec` (repeatable) — one per anchor in the issue's `anchors` array

Compute Round-1 intervals — for each `$I` in `$ANCHORED_ISSUES`, append one `--id` group:

```bash
${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} witness-intervals \
  --reading-model sonnet \
  --cache-dir {{$ANALYSIS_SESSION_PATH}}/cache \
  --mode round-1 \
  --max-frames-per-chunk 20 \
  --frames-output-dir {{$ANALYSIS_SESSION_PATH}} \
  --format json \
  --id <$ANCHORED_ISSUES[$I].id> \
    --temporal-nature <$ANCHORED_ISSUES[$I].temporal_nature> \
    --event-triggered <$ANCHORED_ISSUES[$I].is_input_event_triggered> \
    --has-focus-elements true|false \
    --discourse-start <$ANCHORED_ISSUES[$I].discourse_time_span.start_sec> \
    --discourse-end <$ANCHORED_ISSUES[$I].discourse_time_span.end_sec> \
    --perception-window <$ANCHORED_ISSUES[$I].perception_window_sec> \
    --symptom-duration <$ANCHORED_ISSUES[$I].symptom_duration_sec> \
    --pre-trigger-window <$ANCHORED_ISSUES[$I].pre_trigger_event_window_sec> \
    --anchor <$ANCHORED_ISSUES[$I].anchors[$J].kind>:<$ANCHORED_ISSUES[$I].anchors[$J].at_sec> \
    ...
```

The Round-1 envelope:

```json
{"mode": "round-1", "merge_gap_sec": 0.5, "issues": [{"issue_id": "ISS-001", "intervals": [{...}]}]}
```

Each Round-1 interval: `{id, start_sec, end_sec, source (optional), is_fused (omitted when false), anchor_speech_at (optional), anchor_event_at (optional), preceding_event_at (optional), event_role (optional), frames_dir (optional), frame_paths (optional), frame_count (optional)}`.

When `--frames-output-dir` is set, intervals with more than `--max-frames-per-chunk` unique frames are partitioned into sub-intervals. Each sub-interval has `frames_dir` (relative path to pre-extracted frames), `frame_paths` (list of frame filenames), and `frame_count`.

Set **$R1_DATA** to the envelope's `issues` array.

Compute Round-2 intervals — same `--id` groups as Round-1:

```bash
${ADA_BIN_DIR}/ada query {{$CAPTURE_SESSION}} witness-intervals \
  --reading-model sonnet \
  --cache-dir {{$ANALYSIS_SESSION_PATH}}/cache \
  --mode round-2 \
  --format json \
  --id <$ANCHORED_ISSUES[$I].id> \
    --temporal-nature <$ANCHORED_ISSUES[$I].temporal_nature> \
    --event-triggered <$ANCHORED_ISSUES[$I].is_input_event_triggered> \
    --has-focus-elements true|false \
    --discourse-start <$ANCHORED_ISSUES[$I].discourse_time_span.start_sec> \
    --discourse-end <$ANCHORED_ISSUES[$I].discourse_time_span.end_sec> \
    --perception-window <$ANCHORED_ISSUES[$I].perception_window_sec> \
    --symptom-duration <$ANCHORED_ISSUES[$I].symptom_duration_sec> \
    --pre-trigger-window <$ANCHORED_ISSUES[$I].pre_trigger_event_window_sec> \
    --anchor <$ANCHORED_ISSUES[$I].anchors[$J].kind>:<$ANCHORED_ISSUES[$I].anchors[$J].at_sec> \
    ...
```

The Round-2 envelope:

```json
{"mode": "round-2", "issues": [{"issue_id": "ISS-001", "eligible": true, "sub_intervals": [{...}]}]}
```

Each Round-2 sub-interval: `{id, start_sec, end_sec}`.

Set **$R2_DATA** to the envelope's `issues` array.

#### Derive `start_ns` and `end_ns`

For each interval in `$R1_DATA` issues and each sub-interval in `$R2_DATA` issues:

```pseudo-code
interval.start_ns = (max(0.0, interval.start_sec) * 1_000_000_000) as u64
interval.end_ns   = (max(0.0, interval.end_sec)   * 1_000_000_000) as u64
```

#### Assemble `$INTERVAL_DATA`

Set variable **$INTERVAL_DATA** to:

```json
[
  {
    "issue_id": "ISS-XXX",
    "intervals": [
      {
        "id": "[E-NNN format from witness-intervals tool]",
        "witness_tag": "[equals id]",
        "start_sec": "[float: interval start from witness-intervals tool]",
        "end_sec": "[float: interval end from witness-intervals tool]",
        "start_ns": "[u64: max(0, start_sec) * 1_000_000_000]",
        "end_ns": "[u64: max(0, end_sec) * 1_000_000_000]",
        "source": "event_triggered|speech_triggered",
        "is_fused": true|false,
        "frames_dir": "[optional: relative path to pre-extracted frame directory]",
        "frame_paths": "[optional: array of frame filenames in this chunk]",
        "frame_count": "[optional: integer count of unique frames]"
      }
    ],
    "round_2_intervals": [
      {
        "id": "[E-NNN/R2-SN format from witness-intervals tool]",
        "witness_tag": "[equals id]",
        "start_sec": "[float: sub-interval start]",
        "end_sec": "[float: sub-interval end]",
        "start_ns": "[u64: max(0, start_sec) * 1_000_000_000]",
        "end_ns": "[u64: max(0, end_sec) * 1_000_000_000]"
      }
    ]
  }
]
```

`round_2_intervals` is `null` when the issue is not eligible.

For each issue:

1. Find the issue in `$R1_DATA` by `issue_id`. Collect its enriched intervals (now with `start_ns`, `end_ns`, `witness_tag`).
2. Find the issue in `$R2_DATA` by `issue_id`. If `eligible == true`, collect its enriched sub-intervals. If `eligible == false`, set to `null`.
3. Append to `$INTERVAL_DATA`.

### Step 12.2. Build Issues

Set variable **$ISSUES** to `[]` (an empty JSON array).

For each **$ANCHORED_ISSUE** in **$ANCHORED_ISSUES**:
1. Find the entry in **$INTERVAL_DATA** where `issue_id` equals the `id` field of the **$ANCHORED_ISSUE**.
2. Map the **$ANCHORED_ISSUE** into the following JSON object and append to **$ISSUES**:

   ```json
   {
     "id": issue.id,
     "type": issue.type,
     "severity": issue.severity,
     "temporal_nature": issue.temporal_nature,
     "is_input_event_triggered": issue.is_input_event_triggered,
     "focus_elements": issue.focus_elements,
     "short_description": issue.short_description,
     "description": issue.description,
     "raw_user_quotes": issue.raw_user_quotes,
     "details": issue.details,
     "ambiguities": issue.ambiguities,
     "intervals": $INTERVAL_DATA match's intervals (or []),
     "round_2_intervals": $INTERVAL_DATA match's round_2_intervals (or null)
   }
   ```

You **MUST** write the contents of `$ISSUES` (a JSON array) to `{{$OUTPUT_DIRECTORY}}/observations/issues.json`.
You **MUST NOT** modify the `interval` or `round_2_intervals` entries. Copy them verbatim from the tool output.

### Step 12.3. Write Final JSON

You **MUST** persist the three assembly inputs as files in `{{$OUTPUT_DIRECTORY}}` before invoking `make-json`:

You **MUST NOT** persist any other JSON variable to the filesystem during this step.

<EXTREMELY_IMPORTANT>

You **MUST** assemble the final JSON with the following command, using `--merge` against the three files written above:

```bash
${ADA_BIN_DIR}/ada utilities make-json --output {{$OUTPUT_DIRECTORY}}/user_observations.json \
  --merge session_info={{$OUTPUT_DIRECTORY}}/observations/session_info.json \
  --merge issues={{$OUTPUT_DIRECTORY}}/observations/issues.json \
  --merge unattached_ambiguities={{$OUTPUT_DIRECTORY}}/observations/unattached_ambiguities.json
```

You **MUST** substitute `{{}}`-protected variables with their contents from the context.
You **MUST NOT** change the fields composition approach defined in the command example above from `--merge KEY=FILE` to `--set KEY=JSON_VALUE`.

</EXTREMELY_IMPORTANT>

### Response

Your response to the caller MUST be ONLY the following JSON — no preamble, no summary, no explanation, no markdown fences:

{"status": "complete", "issue_count": [N], "has_ambiguities": true|false}

Where `[N]` is the number of issues in $ANCHORED_ISSUES and `true|false` reflects whether any issue has non-empty `ambiguities` or `unattached_ambiguities` is non-empty.

Do NOT include any text before or after this JSON. The caller reads all observation data from `user_observations.json` on disk.

## Error Handling

### No Transcript Available

If `transcribe tokens` returns empty or fails, your response MUST be ONLY this JSON — no other text:

{"status": "error", "error": "no_voice_recording", "issue_count": 0, "has_ambiguities": false, "fallback_suggestion": "Analyze using screenshots and trace events only"}

### No Issues Found

If transcript exists but contains no bug reports, improvements, or feature requests, do NOT run `make-json`. Your response MUST be ONLY this JSON — no other text:

{"status": "complete", "issue_count": 0, "has_ambiguities": false}

## Important Notes

1. **Preserve User Observations**: Use their exact words in `raw_user_quotes` - don't paraphrase
2. **Time Window Buffer**: Add 5 seconds before/after the mentioned time to catch setup and aftermath
3. **Keyword Selection**: Extract nouns and verbs that would appear in function/class names
4. **Conservative Classification**: When unsure between severities, choose the lower one
5. **One Issue Per Concern**: Each distinct concern (Step 4) produces one issue, which may have multiple anchors within it
6. **No Editorial Commentary**: Do NOT editorialize about whether an issue is a "design proposal" or "not a bug" in your summary text. Classify the `type` field accurately and let the orchestrator handle routing. Your job is extraction and classification, not triage decisions.
