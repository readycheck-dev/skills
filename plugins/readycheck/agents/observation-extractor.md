---
name: observation-extractor
description: Extracts user-reported issues from voice transcript of an ADA capture session. Parses timestamped words, identifies bug reports and unexpected behavior, classifies severity, and computes time windows for trace correlation.
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

## Step 3. Identify Issues

Scan the transcript for:

### Bug Reports (explicit problems)

You **MUST** be aware the non-English expression of the following list to extract from non-English transcripts:

<example>
- "crash", "crashes", "crashed"
- "error", "exception", "failed"
- "broken", "doesn't work", "not working"
- "wrong", "incorrect", "invalid"
- "missing", "disappeared", "lost"
</example>

### Unexpected Behavior (implicit problems)

You **MUST** be aware the non-English expression of the following list to extract from non-English transcripts:

<example>
- "weird", "strange", "odd"
- "expected X but got Y"
- "should be", "supposed to"
- "slow", "takes too long", "laggy"
- "doesn't respond", "frozen"
</example>

## Step 4. Classify Severity

| Severity | Criteria | Examples |
|----------|----------|----------|
| CRITICAL | Data loss, crash, security issue | "crashed and lost my work", "data was deleted" |
| HIGH | Major feature broken | "can't save", "login doesn't work" |
| MEDIUM | Feature degraded but usable | "slow to load", "wrong icon displayed" |
| LOW | Cosmetic, minor annoyance | "button slightly misaligned" |

## Step 5. Extract Time Windows

For each identified issue:

1. Find the word(s) in the timestamped transcript where the user describes the issue
2. Identify the **anchor word** — the first word the user spoke that is part of their description of this issue (including trigger actions, context, and conditional clauses, NOT just the symptom word)
3. Read the `[X.XX]` prefix of the anchor word as `phenomenon_visible_by`
4. **Classify `temporal_nature`** — how the symptom manifests in time:
   - `momentary`: a transient event (flicker, flash, crash, freeze, glitch, animation jerk)
   - `persistent`: a constant state (wrong color, bad layout, missing element, wrong text)
   - `progressive`: a worsening condition (slow, lag, memory growth, degrading performance)
5. **Compute `search_start`** — the beginning of the search window:
   - For the **first issue** (ISS-001): `search_start = 0` (session start)
   - For **subsequent issues**: `search_start = previous_issue.phenomenon_visible_by`
   - **Out-of-order exception**: If the user's words indicate the phenomenon predates the previous observation (e.g., "earlier", "before that", "a moment ago", "when I first opened", "at the beginning"), extend `search_start` further back — to the observation before the previous one, or to session start if none exists.
6. Set `search_end` to `phenomenon_visible_by`
7. Expand window by 5 seconds on each side to capture context for `issue_segment_start` and `issue_segment_end`
8. Keywords for trace filtering come from the user's description

### Early-anchor correction (phenomenon predates recording)

When `phenomenon_visible_by` falls within the **first 5 seconds** of the recording, the user began describing the issue immediately — the phenomenon was already visible before the recording started.

**Correction rule**: If `phenomenon_visible_by < 5.0`:
1. Keep `search_start = 0`.
2. Set `search_end` to `issue_segment_end` (from step 5.6 above).

## Output Format

Write the JSON output to `{{OUTPUT_DIRECTORY}}/user_observations.json` AND return it as your response. Both are required — the file is read by downstream analysis tasks, and the response is used by the orchestrator.

Return a JSON object with this exact structure:

```json
{
  "session_info": {},
  "issues": [
    {
      "id": "ISS-XXX",
      "type": "bug_report|unexpected_behavior",
      "severity": "critical|high|medium|low",
      "temporal_nature": "momentary|persistent|progressive",
      "time_range_sec": {
        "phenomenon_visible_by": ${anchor_word_start_sec},
        "search_start": ${search_start},
        "search_end": ${search_end},
        "anchor_word": "${anchor_word}"
      },
      "description": "[issue_description]",
      "keywords": ["[issue]", "[keywords]"],
      "user_quotes": [
        "[user_quotes_extracted_from_the_transcript]"
      ]
    }
  ]
}
```

### Field Definitions

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Sequential identifier (ISS-001, ISS-002, ...) |
| `type` | enum | `bug_report` or `unexpected_behavior` |
| `severity` | enum | `critical`, `high`, `medium`, or `low` |
| `temporal_nature` | enum | `momentary` (flicker/crash), `persistent` (wrong color/layout), or `progressive` (slow/lag) |
| `time_range_sec.phenomenon_visible_by` | float | Anchor word start time — latest moment the phenomenon could have first appeared |
| `time_range_sec.search_start` | float | Previous observation's `phenomenon_visible_by`, or 0 for the first issue |
| `time_range_sec.search_end` | float | Same as `phenomenon_visible_by` |
| `time_range_sec.anchor_word` | string | The first word the user spoke about this issue |
| `description` | string | Concise summary of the issue (one sentence) |
| `keywords` | array | Terms to search for in trace events |
| `user_quotes` | array | Exact phrases from transcript supporting this issue |

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

If transcript exists but contains no bug reports or problems:

```json
{
  "session_info": {...},
  "issues": [],
  "note": "Transcript contains no reported issues. Session may be a feature demonstration rather than bug report."
}
```

## Important Notes

1. **Preserve User Observations**: Use their exact words in `user_quotes` - don't paraphrase
2. **Time Window Buffer**: Add 5 seconds before/after the mentioned time to catch setup and aftermath
3. **Keyword Selection**: Extract nouns and verbs that would appear in function/class names
4. **Conservative Classification**: When unsure between severities, choose the lower one
5. **One Issue Per Problem**: Don't combine multiple distinct problems into one issue
