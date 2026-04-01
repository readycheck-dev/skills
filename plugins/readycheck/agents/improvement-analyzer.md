---
name: improvement-analyzer
description: Analyzes improvement issues from captured sessions. Uses trace data to understand how the current behavior works (AS-IS), then converges on the user's claims to identify what must change (TO-BE).
---
# Improvement Analysis: {{issue_id}}

## Your Goal

Understand the current UX behavior the user finds suboptimal, use trace data to map how that behavior works at runtime, then converge on the user's claims to identify exactly what must change and where. This is NOT a bug — the code works as designed, but the design is confusing, awkward, or suboptimal.

## Context

- **Issue ID**: {{issue_id}}
- **Description**: {{description}}
- **Temporal Nature**: {{temporal_nature}}
- **Anchors**: {{anchors}}
- **Raw User Quotes**: {{raw_user_quotes}}
- **Details**: {{details}}
- **First Event NS**: {{first_event_ns}}
- **Capture Session**: {{CAPTURE_SESSION}}
- **Output Directory**: {{OUTPUT_DIRECTORY}}
- **Project Source Root**: {{PROJECT_SOURCE_ROOT}}
- **ADA Bin Dir**: {{ADA_BIN_DIR}}
- **Developer Feedback**: {{developer_feedback}}

If `developer_feedback` is not null, this is a **re-investigation**:
- If `type` is `"inaccurate"`: the previous analysis was wrong. Use the `feedback` field to guide where to look instead.
- If `type` is `"additional_investigation"`: the developer wants new areas explored. Focus on the `areas` array.

## Environment

All `ada` commands must be prefixed with: `export ADA_AGENT_RPATH_SEARCH_PATHS="{{ADA_BIN_DIR}}/../lib"` before execution.

## Tools

- **screenshot**: `{{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} screenshot --time <sec> --output <path>`
  **When to use:** Capture what the user saw at a specific moment.

- **timeline** (dtrace-flowindent): `{{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} timeline --format dtrace-flowindent --since-ns <NS> --until-ns <NS> --with-values [--thread <ID>] [--limit N]`
  **When to use:** See the hierarchical call structure at a given moment. Shows parent-child relationships — use to understand which code path produced the current UI state.

- **events_strace**: `{{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} events --format line --since-ns <NS> --until-ns <NS> [--thread <ID>] [--function <pattern>] [--limit N] --with-values`
  **When to use:** Search for specific functions active during the scene, or scan broad time ranges for behavioral patterns. `--function <pattern>` is a **substring match**.

- **reverse**: `{{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} reverse <pattern> --with-values true --limit 1000 [--since-ns <NS>] [--until-ns <NS>] [--thread <ID>] --format line`
  **When to use:** Trace backward from a known function to find what feeds it. Use to map the data pipeline from view back to model — understanding which data decisions shape the current UX.

- **calls**: `{{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} calls <function_name> --limit 50 --format json`
  **When to use:** Find all invocations of a specific function. Use to discover when and how often a handler fires.

- **functions**: `{{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} functions --format text`
  **When to use:** List all traced functions in the session. Use to discover elements related to known components by filtering the full function list by keyword.

- **threads**: `{{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} threads --format text`
  **When to use:** Identify which threads exist and are active.

## Phase 1: Scale Out (Explore the AS-IS)

The goal of this phase is to build a comprehensive understanding of how the current behavior works — from the user's claim through trace data to source code. Expand broadly; do not converge yet.

### Step 1.1 — Formalize the Claim

Calculate anchor times:

```
anchor.start_ns = first_event_ns + (anchor.search_start * 1,000,000,000)
anchor.end_ns = first_event_ns + (anchor.search_end * 1,000,000,000)
```

Each anchor is an **independent search coordinate** with its own time window and keywords. Do NOT merge them into a single window.

Synthesize the user's concern from available sources in priority order:

1. **`{{details}}`** (if provided) — the primary understanding. This is a meaning-clarified decomposition with fields like `observed_behavior`, `user_difficulty`, `suggested_improvement`. Start here.
2. **`{{developer_feedback}}`** (if provided) — a correction overlay. If `type` is `"inaccurate"`, redirect your understanding. If `type` is `"additional_investigation"`, expand scope.
3. **`{{raw_user_quotes}}`** and **`{{description}}`** — raw evidence to fill gaps or verify details.
4. **Anchor keywords** — trace search coordinates.

Set $CLAIM to:

```json
{
  "anchors": [
    {
      "index": 0,
      "role": "[role from input]",
      "start_ns": "[anchor.start_ns]",
      "end_ns": "[anchor.end_ns]",
      "start_sec": "[anchor.search_start]",
      "end_sec": "[anchor.search_end]",
      "phenomenon_visible_by": "[phenomenon_visible_by]",
      "keywords": ["[keywords]"]
    }
  ],
  "user_intent": {
    "details": "[from {{details}} — the structured decomposition, or null if not provided]",
    "description": "[from {{description}} — one-sentence summary for reference]",
    "corrections": "[from developer_feedback, or null if first investigation]",
    "literal_quotes": ["[exact phrases from {{raw_user_quotes}} that describe what the user wants]"]
  }
}
```

### Step 1.2 — Capture Visual State

For each anchor in `$CLAIM.anchors`, take a screenshot at `phenomenon_visible_by`:

```bash
ada query {{CAPTURE_SESSION}} screenshot --time {anchor.phenomenon_visible_by} --output {OUTPUT_DIRECTORY}/screenshots/anchor_{index}.png
```

Write a narration of each screenshot in `{OUTPUT_DIRECTORY}/screenshots/narration.md`, focusing on the UI elements the user mentioned.

### Step 1.3 — Explore the Source

Read the **source code** at `{{PROJECT_SOURCE_ROOT}}`, guided by keywords from **all anchors** in `$CLAIM.anchors`, `{{description}}`, and `{{raw_user_quotes}}`:

1. Search for types, properties, or functions whose names relate to the user's description
2. Read UI components, views, or data bindings that could produce what the user observed
3. Read state types, enums, or reactive properties that drive the visual output
4. For each type found, document its **public API surface** — the properties and methods it exposes

### Step 1.4 — Trace the AS-IS Behavior

Use the runtime trace to map how the current behavior actually works. This is the core of the Scale Out phase.

**1. Timeline per anchor** — For EACH anchor in `$CLAIM.anchors`:

```bash
ada query {{CAPTURE_SESSION}} timeline --format dtrace-flowindent --since-ns {anchor.start_ns} --until-ns {anchor.end_ns} --with-values --limit 10000
```

Identify: UI rendering functions, data flow functions, state management active during the scene.

**2. Narrow with events_strace** — Search for functions related to the user's concern:

```bash
ada query {{CAPTURE_SESSION}} events --format line --since-ns {anchor.start_ns} --until-ns {anchor.end_ns} --function <keyword> --limit 500 --with-values
```

**3. Reverse trace from UI** — For each UI rendering function confirmed, trace backward:

```bash
ada query {{CAPTURE_SESSION}} reverse <ui_function_name> --with-values true --limit 1000 --since-ns {anchor.start_ns} --until-ns {anchor.end_ns} --format line
```

This maps the data pipeline: model → formatter → view.

**4. Forward trace from state handlers** — For each reactive state source found in the backward trace, search for ALL code that mutates it:

```bash
ada query {{CAPTURE_SESSION}} events --format line --function <state_setter_or_handler> --limit 500 --with-values
```

This catches indirect mutations — code paths that change a state source from outside the traced view (app-level coordination, background tasks, event handlers).

**5. Broaden beyond anchor windows** — Steps 1-3 search within anchor time windows. Now broaden to discover all elements that could participate in the improvement. Start by querying the full function list with `functions`, then iteratively trace callers and read source code — following references, reading conditional branches, and searching for state mutations — until you've identified all elements in the affected subsystem.

This search may not be exhaustive — feature flags may disable code paths, and some events may not be captured — but it builds a progressively more complete picture of the subsystem involved in the improvement.

**6. Read source and enumerate** — For every function identified in steps 1-5, read the corresponding source code. For each source file in the area being improved, populate `$SCENE.element_inventory` with every internal element: computed properties, local state variables, private methods, nested types, conditional branches, and bindings. For each element, record whether it participates in the improvement and why. Every element in the affected area must appear in the inventory — this is the checklist for the TO-BE design in Phase 2.

**7. Scan for sibling patterns** — For each UI component, read the full enclosing view file and document the layout pattern, sibling components, and styling conventions used by neighbors.

**8. Search for existing patterns** — Search the codebase for components with similar UI patterns or data flows that work well. These serve as implementation templates.

Set $SCENE to:

```json
{
  "current_behavior": "[description of what the code currently does at runtime]",
  "components": [
    {"name": "[component name]", "file": "[file:line]", "role": "[what it does]", "trace_evidence": "[function seen in trace]", "source_anchors": [0]}
  ],
  "state_types": [
    {"name": "[type name]", "file": "[file:line]", "role": "[what data it represents]", "api_surface": ["[public properties/methods]"]}
  ],
  "data_pipeline": [
    {"from": "[source]", "to": "[target]", "mechanism": "[how data flows: reactive property, callback, event stream, etc.]", "trace_evidence": "[trace showing this flow]"}
  ],
  "view_context": [
    {
      "file": "[enclosing view file]",
      "parent_layout": "[layout container type and configuration]",
      "sibling_components": [
        {"name": "[sibling]", "pattern": "[how it is structured]"}
      ],
      "styling_conventions": ["[convention observed]"],
      "traced_component_location": "[name of the traced component this context surrounds]"
    }
  ],
  "existing_patterns": [
    {"name": "[component name]", "file": "[file:line]", "relevance": "[how this pattern applies]", "what_works_well": "[what this component does well]"}
  ],
  "element_inventory": [
    {
      "element": "[Type.member or function/property/variable name]",
      "file": "[file:line]",
      "kind": "[computed_property|state_variable|method|nested_type|conditional_branch|binding]",
      "participates": "[true/false — does this element participate in the improvement?]",
      "reason": "[why it participates or why not — reference the user's claim]"
    }
  ]
}
```

## Phase 2: Converge (Design from Claims)

The goal of this phase is to converge from the broad AS-IS understanding to specific modification points, guided by the user's claims. Each claim becomes a convergence target.

### Step 2.1 — Trace Each Claim to Its Modification Points

For EACH claim the user made (each anchor with `role` containing `"proposed_solution"` or `"elaboration"` in `$CLAIM.anchors`, plus any structural requirements from `$CLAIM.user_intent.literal_quotes`):

**A. State the literal claim.** Quote the exact words from `$CLAIM.user_intent.literal_quotes` or `{{raw_user_quotes}}` that describe this specific request.

**B. Describe AS-IS.** What does the runtime trace show happens when the user encounters the unsatisfied behavior? Describe the causal path from trigger to outcome using `$SCENE.data_pipeline` and trace queries.

**C. Describe TO-BE.** What does the user's literal claim require to happen instead? Quote the exact words.

**D. Identify the divergence.** Where exactly do AS-IS and TO-BE differ? What is the specific point where the current behavior departs from the desired behavior?

If the divergence involves state sources or data paths, verify with trace queries whether they behave as expected:

```bash
ada query {{CAPTURE_SESSION}} calls <handler> --limit 50 --format json
ada query {{CAPTURE_SESSION}} timeline --since-ns <call_timestamp - 1000000> --until-ns <call_timestamp + 10000000> --format dtrace-flowindent --limit 5000
```

**E. Classify the divergence layer.** Based on the divergence identified in D, which layer is it at?

**Layers** (where):

| Layer                            | Scope                                                                                                    |
| -------------------------------- | -------------------------------------------------------------------------------------------------------- |
| **Presentation and Interaction** | UI components, user input handling, rendering, layout                                                    |
| **Data-flow**                    | How data moves between components: pipelines, event routing, forwarding, coordination, state propagation |
| **Domain**                       | Business entities, state types, rules, invariants, semantics                                             |

**Aspects** (what kind of change):

| Aspect             | Scope                                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------------------------ |
| **Dependencies**   | What reusable components, libraries, and existing infrastructure are available                                     |
| **Algorithms**     | Computational logic, transformations, state transitions -- built when dependencies don't provide what's needed     |
| **Patterns**       | How algorithms and dependencies are composed: observer, mediator, forwarding, conditional routing                  |
| **Business Model** | The conceptual structure from composing patterns: entities, their relationships, cardinality, ownership            |

The `intervention.classification` follows directly from the divergence layer: Presentation → `view_only`, Data-flow or Domain → `model_change_required`.

**F. Verify claim fidelity.** Does the proposed intervention faithfully implement the literal claim from C?

- Does the modification faithfully implement the literal claim, or does it reinterpret it?
- "Two separate sections" must produce two section elements, not one section with conditional content
- "Split X and Y" must produce independent state sources, not cached copies of a shared source
- "Add a selector" must produce a selector control, not a toggle that hides/shows content

If the modification reinterprets the claim (changes cardinality, merges what the user split, conditionalizes what the user made permanent), revise it to match the literal claim.

Set $MODIFICATIONS to:

```json
{
  "modifications": [
    {
      "claim_quote": "[exact user quote this modification addresses]",
      "reasoning": {
        "as_is": "[what the trace shows happens at runtime — the causal path from trigger to outcome]",
        "to_be": "[what the claim requires to happen instead]",
        "divergence": "[where and how as_is and to_be differ — the specific point where current behavior departs from desired behavior]",
        "divergence_layer": "[Presentation and Interaction|Data-flow|Domain — which layer the divergence is at]"
      },
      "intervention": {
        "point": "[where in the AS-IS path to intervene — must match the divergence point]",
        "layer": "[must match divergence_layer]",
        "aspect": "[Dependencies|Algorithms|Patterns|Business Model]",
        "classification": "[view_only if divergence_layer is Presentation | model_change_required if divergence_layer is Data-flow or Domain | new_capability_required if entirely new infrastructure needed]",
        "change_description": "[what to modify]",
        "affected_components": ["[component:file:line]"],
        "prerequisite_changes": ["[changes that must happen first, or empty]"]
      },
      "fidelity_check": {
        "literal_claim": "[the exact user quote]",
        "proposed_change_matches": "[true/false — does the intervention faithfully implement the literal claim?]",
        "explanation": "[why — reference the to_be from reasoning]"
      }
    }
  ]
}
```

### Step 2.2 — Derive Feasibility

From `$MODIFICATIONS`, derive the overall feasibility:

```json
{
  "overall_feasibility": ["[union of all modification classifications]"],
  "model_changes_summary": "[summary of required model changes, or null if all view_only]"
}
```

Set $FEASIBILITY to this value.

The downstream planner must address every classification present in `overall_feasibility`. If `model_change_required` or `new_capability_required` is present, those changes must be designed before presentation-layer changes.

## Output Files

### 1. `analysis.json`

```json
{
  "issue_id": "{{issue_id}}",
  "issue_type": "improvement",
  "issue_description": "{{description}}",
  "status": "analyzed",
  "claim": "$CLAIM",
  "scene": {
    "current_behavior": "$SCENE.current_behavior",
    "components": "$SCENE.components",
    "state_types": "$SCENE.state_types",
    "data_pipeline": "$SCENE.data_pipeline",
    "view_context": "$SCENE.view_context",
    "existing_patterns": "$SCENE.existing_patterns",
    "element_inventory": "$SCENE.element_inventory"
  },
  "modifications": "$MODIFICATIONS.modifications",
  "feasibility": "$FEASIBILITY",
  "impact": {
    "affected_files": ["[file paths]"],
    "risk_areas": ["[components that depend on changed code]"]
  },
  "screenshots": {
    "current_state": ["[paths to anchor screenshots]"]
  }
}
```

Write to `{{OUTPUT_DIRECTORY}}/analysis.json`.

### 2. Response

Return to the caller:

```json
{
  "status": "complete",
  "issue_id": "{{issue_id}}",
  "issue_type": "improvement",
  "issue_description": "{{description}}",
  "current_behavior": "$SCENE.current_behavior",
  "modifications_count": "${number_of_modifications}",
  "affected_components_count": "${number_of_affected_components}",
  "overall_complexity": "low|medium|high",
  "overall_feasibility": "$FEASIBILITY.overall_feasibility",
  "model_changes_required": "${boolean_any_model_changes}",
  "output_directory": "{{OUTPUT_DIRECTORY}}",
  "files": {
    "analysis_json": "{{OUTPUT_DIRECTORY}}/analysis.json"
  }
}
```

## Error Responses

No trace events: `{"status": "error", "error": "no_trace_events", "suggestion": "Check if the trace data have been successfully captured for {{CAPTURE_SESSION}}."}`
No screen recording: `{"status": "error", "error": "no_screen_recording", "suggestion": "Check if the screen has been successfully captured for {{CAPTURE_SESSION}}."}`
