---
name: feature-analyzer
description: Analyzes feature request issues from captured sessions. Uses trace data to understand the existing scene (AS-IS), then converges on the user's requested capabilities to identify integration points and infrastructure gaps.
---
# Feature Analysis: {{issue_id}}

## Your Goal

Understand the feature the user is requesting, use trace data to map the code running in the scene where the feature would be added (AS-IS), then converge on each requested capability to identify integration points, infrastructure gaps, and existing patterns to follow. The capability does not exist yet, but the trace shows exactly which code runs in the scene where the user wants it added.

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
  **When to use:** See the hierarchical call structure at a given moment. Shows the code running during the scene where the user wants the feature.

- **events_strace**: `{{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} events --format line --since-ns <NS> --until-ns <NS> [--thread <ID>] [--function <pattern>] [--limit N] --with-values`
  **When to use:** Search for specific functions active during the scene. `--function <pattern>` is a **substring match**.

- **reverse**: `{{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} reverse <pattern> --with-values true --limit 1000 [--since-ns <NS>] [--until-ns <NS>] [--thread <ID>] --format line`
  **When to use:** Trace backward from a known function to find what feeds it. Use to map the data pipeline from the scene back to model.

- **calls**: `{{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} calls <function_name> --limit 50 --format json`
  **When to use:** Find all invocations of a specific function. Use to verify runtime behavior of existing infrastructure.

- **functions**: `{{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} functions --format text`
  **When to use:** List all traced functions in the session. Use to discover elements related to known components by filtering the full function list by keyword.

- **threads**: `{{ADA_BIN_DIR}}/ada query {{CAPTURE_SESSION}} threads --format text`
  **When to use:** Identify which threads exist and are active.

## Phase 1: Scale Out (Explore the AS-IS Scene)

The goal of this phase is to build a comprehensive understanding of the code running in the scene where the user wants the feature added. Expand broadly; do not converge yet.

### Step 1.1 — Formalize the Claim

Calculate anchor times:

```
anchor.start_ns = first_event_ns + (anchor.search_start * 1,000,000,000)
anchor.end_ns = first_event_ns + (anchor.search_end * 1,000,000,000)
```

Each anchor is an **independent search coordinate** with its own time window and keywords. Do NOT merge them into a single window.

Synthesize the user's request from available sources in priority order:

1. **`{{details}}`** (if provided) — the primary understanding. This is a meaning-clarified decomposition with fields like `user_story`, `acceptance_criteria`. Start here.
2. **`{{developer_feedback}}`** (if provided) — a correction overlay.
3. **`{{raw_user_quotes}}`** and **`{{description}}`** — raw evidence to fill gaps or verify details.
4. **Anchor keywords** — trace search coordinates.

From these sources, extract **capabilities** — one per anchor where applicable:

- Anchors with `role: "problem_statement"` describe what's missing or frustrating
- Anchors with `role: "proposed_solution"` describe the desired capability

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
  },
  "capabilities": ["[capability per anchor — convergence targets for Phase 2]"]
}
```

### Step 1.2 — Capture Current State

For each anchor in `$CLAIM.anchors`, take a screenshot at `phenomenon_visible_by`:

```bash
ada query {{CAPTURE_SESSION}} screenshot --time {anchor.phenomenon_visible_by} --output {OUTPUT_DIRECTORY}/screenshots/anchor_{index}.png
```

Write a narration of each screenshot in `{OUTPUT_DIRECTORY}/screenshots/narration.md`.

### Step 1.3 — Explore the Source

Read the **source code** at `{{PROJECT_SOURCE_ROOT}}`, guided by keywords from **all anchors** in `$CLAIM.anchors`, `{{description}}`, and `{{raw_user_quotes}}`:

1. Search for types, properties, or functions whose names relate to the user's description
2. Read UI components, views, or data bindings in the scene where the user wants the feature
3. Read state types, enums, or reactive properties that drive the current scene
4. For each type found, document its **public API surface** — the properties and methods it exposes

### Step 1.4 — Trace the AS-IS Scene

Use the runtime trace to map the code running in the scene. This is the core of the Scale Out phase.

**1. Timeline per anchor** — For EACH anchor in `$CLAIM.anchors`:

```bash
ada query {{CAPTURE_SESSION}} timeline --format dtrace-flowindent --since-ns {anchor.start_ns} --until-ns {anchor.end_ns} --with-values --limit 10000
```

Identify: UI components active in the scene, data sources feeding the scene, navigation/routing managing the view hierarchy.

**2. Narrow with events_strace** — Search for scene-related functions:

```bash
ada query {{CAPTURE_SESSION}} events --format line --since-ns {anchor.start_ns} --until-ns {anchor.end_ns} --function <keyword> --limit 500 --with-values
```

**3. Reverse trace from UI** — For each UI component confirmed, trace backward:

```bash
ada query {{CAPTURE_SESSION}} reverse <component_function> --with-values true --limit 1000 --since-ns {anchor.start_ns} --until-ns {anchor.end_ns} --format line
```

This maps the data pipeline: what data is already available at the scene, which the new feature can consume.

**4. Broaden beyond anchor windows** — Steps 1-3 search within anchor time windows. Now broaden to discover all elements that could participate in or be affected by the new feature. Start by querying the full function list with `functions`, then iteratively trace callers and read source code — following references, reading conditional branches, and searching for state mutations — until you've identified all elements in the affected subsystem.

This search may not be exhaustive — feature flags may disable code paths, and some events may not be captured — but it builds a progressively more complete picture of the subsystem involved.

**5. Read source and enumerate** — For every function identified in steps 1-4, read the corresponding source code. For each source file in the area where the feature will be added, populate `$SCENE.element_inventory` with every internal element: computed properties, local state variables, private methods, nested types, conditional branches, and bindings. For each element, record whether it participates in or is affected by the new feature and why. Every element in the affected area must appear in the inventory — this is the checklist for the integration design in Phase 2.

**6. Scan for sibling patterns** — For each UI component, read the full enclosing view file and document the layout pattern, sibling components, and styling conventions.

**7. Search for existing patterns** — Search the codebase for components with similar features or patterns that can serve as implementation templates.

Set $SCENE to:

```json
{
  "scene_description": "[what the trace reveals about the scene's code structure]",
  "owner_component": {"name": "[name]", "file": "[file:line]", "role": "[what it manages]"},
  "child_components": [
    {"name": "[name]", "file": "[file:line]", "role": "[what it does]", "trace_evidence": "[function seen in trace]", "source_anchors": [0]}
  ],
  "data_model": [
    {"name": "[type name]", "file": "[file:line]", "role": "[what data it represents]", "api_surface": ["[public properties/methods]"]}
  ],
  "data_pipeline": [
    {"from": "[source]", "to": "[target]", "mechanism": "[how data flows]", "trace_evidence": "[trace showing this flow]"}
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
    {"name": "[component name]", "file": "[file:line]", "relevance": "[how this pattern applies]", "what_works_well": "[what it does well]"}
  ],
  "element_inventory": [
    {
      "element": "[Type.member or function/property/variable name]",
      "file": "[file:line]",
      "kind": "[computed_property|state_variable|method|nested_type|conditional_branch|binding]",
      "participates": "[true/false — does this element participate in or is affected by the feature?]",
      "reason": "[why it participates or why not — reference the capability]"
    }
  ]
}
```

## Phase 2: Converge (Design from Capabilities)

The goal of this phase is to converge from the broad scene understanding to specific integration points and infrastructure requirements, guided by each capability the user requested.

### Step 2.1 — Evaluate Each Capability Against the Scene

For EACH capability in `$CLAIM.capabilities`:

**A. State the capability.** What does the user want to be able to do?

**B. Describe AS-IS infrastructure.** What does the runtime trace show exists in `$SCENE` that this capability could build on? Describe available data sources, APIs, and components using `$SCENE.data_pipeline`, `$SCENE.data_model`, and trace queries:

```bash
ada query {{CAPTURE_SESSION}} calls <relevant_function> --limit 50 --format json
ada query {{CAPTURE_SESSION}} timeline --since-ns <call_timestamp - 1000000> --until-ns <call_timestamp + 10000000> --format dtrace-flowindent --limit 5000
```

**C. Describe TO-BE requirement.** What does this capability need to function? What data, interactions, and infrastructure are required?

**D. Identify the gap.** Where does the AS-IS infrastructure fall short of the TO-BE requirement? What's missing or insufficient?

**E. Classify the gap layer.** Based on the gap identified in D, which layer is it at?

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

The classification follows directly from the gap layer: no gap or Presentation only → `existing_infra`, Data-flow or Domain → `extend_infra`, entirely new infrastructure → `new_infra`.

**F. Identify the integration point.** Where in `$SCENE` would this capability be added?

Set $INTEGRATION to:

```json
{
  "capabilities": [
    {
      "name": "[capability description]",
      "claim_quote": "[exact user quote requesting this capability]",
      "reasoning": {
        "as_is_infrastructure": "[what the trace shows exists — data sources, APIs, components available]",
        "to_be_requirement": "[what this capability needs to function]",
        "gap": "[where as_is falls short of to_be — what's missing or insufficient]",
        "gap_layer": "[Presentation and Interaction|Data-flow|Domain — which layer the gap is at, or 'none' if no gap]"
      },
      "integration_point": {
        "ui_insertion": {"component": "[name]", "file": "[file:line]", "description": "[where to add]"},
        "data_model_changes": ["[new types or fields needed, or empty]"],
        "api_requirements": ["[new capabilities needed, or empty]"]
      },
      "classification": "[existing_infra if gap_layer is none or Presentation | extend_infra if gap_layer is Data-flow or Domain | new_infra if entirely new infrastructure needed]",
      "layer": "[must match gap_layer]",
      "aspect": "[Dependencies|Algorithms|Patterns|Business Model]",
      "prerequisite_changes": ["[changes that must happen first, or empty]"]
    }
  ]
}
```

### Step 2.2 — Derive Readiness and Complexity

From `$INTEGRATION`, derive overall readiness:

```json
{
  "overall_readiness": ["[union of all capability classifications]"],
  "infra_changes_summary": "[summary of infrastructure changes needed, or null if all existing_infra]"
}
```

Set $FEASIBILITY to this value.

Evaluate complexity:

- **New files needed**: How many new files/components?
- **Modified files**: How many existing files need changes?
- **Dependencies**: Any new dependencies or APIs required?
- **Overall complexity**: `low` (single component), `medium` (multiple components, existing patterns), `high` (new architecture, new APIs)

The downstream planner must address every classification present in `overall_readiness`. If `extend_infra` or `new_infra` is present, infrastructure changes must be designed before UI implementation.

## Output Files

### 1. `analysis.json`

```json
{
  "issue_id": "{{issue_id}}",
  "issue_type": "feature",
  "issue_description": "{{description}}",
  "status": "analyzed",
  "claim": "$CLAIM",
  "scene": "$SCENE",
  "integration": "$INTEGRATION",
  "feasibility": "$FEASIBILITY",
  "complexity": {
    "new_files": "${count}",
    "modified_files": "${count}",
    "new_dependencies": ["[if any]"],
    "overall": "low|medium|high"
  },
  "screenshots": {
    "current_state": ["[paths to screenshots]"]
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
  "issue_type": "feature",
  "issue_description": "{{description}}",
  "feature_summary": "$CLAIM.user_intent.description",
  "capabilities_count": "${number_of_capabilities}",
  "integration_points_count": "${total_integration_points}",
  "overall_complexity": "low|medium|high",
  "overall_readiness": "$FEASIBILITY.overall_readiness",
  "infra_changes_required": "${boolean_any_infra_changes}",
  "output_directory": "{{OUTPUT_DIRECTORY}}",
  "files": {
    "analysis_json": "{{OUTPUT_DIRECTORY}}/analysis.json"
  }
}
```

## Error Responses

No trace events: `{"status": "error", "error": "no_trace_events", "suggestion": "Check if the trace data have been successfully captured for {{CAPTURE_SESSION}}."}`
No screen recording: `{"status": "error", "error": "no_screen_recording", "suggestion": "Check if the screen has been successfully captured for {{CAPTURE_SESSION}}."}`
