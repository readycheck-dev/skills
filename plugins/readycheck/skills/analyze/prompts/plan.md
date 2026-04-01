# Unified Plan

You are an expert software engineer designing a holistic plan for all issues identified in an analysis session. Issues may be bugs, improvements, features, or a mix. Your plan **MUST** consider all issues together — detecting overlapping components, resolving conflicts, and producing one coherent plan with a single ordered task list.

## Step 1: Read All Analysis Data

Read the analysis session from the directory provided in the task prompt.

List `{{$ANALYSIS_SESSION_PATH}}/issues/` to find all identified issues.

**For each issue directory:**

1. Read `analysis.json`
2. Note the `issue_type` (bug, improvement, or feature)

**Per issue type, read the following fields:**

**Bug issues** (`issue_type == "bug"`):

From `analysis.json`:

- `user_claim`: Structured claim object — `user_claim.details` contains the meaning-clarified decomposition of the user's oral observation (context, not ground truth); `user_claim.description` is a one-sentence summary; `user_claim.corrections` contains developer feedback if re-investigating
- `confirmed_issue`: The confirmed issue after trace investigation
- `behavioral_characterization`: How the bug manifests
- `causal_chain[]`: Each level of the causal chain with function, file, role, trace evidence
- `defect`: Summary, site, chain depth, root cause level, confidence
- `fix_strategy`: Summary, site, level, rationale, scope coverage
- `scope`: State mutation map
- `evidence`: Trace-based evidence

Additional trace artifacts (read from issue directory):

- `traces/causal_sequence.txt` — function call ordering and timing
- `traces/state_emissions.txt` — every state-emitting path with exact guard expressions (your checklist for state emission audit)
- `causal_chain.md` — mechanism documentation and full upstream trace

Pay close attention to:

- **state_emissions.txt**: Every unguarded emission path is a potential fix target
- **causal_chain.md**: The causal chain reveals exactly which functions participate in the bug

**Improvement issues** (`issue_type == "improvement"`):

- `scene.current_behavior`: What the code currently does at runtime
- `scene.components`: UI components and source files involved (with trace evidence)
- `scene.state_types`: Data types that drive the current behavior (with `api_surface`)
- `scene.data_pipeline`: How data flows from model through transforms to view (trace-verified, including indirect mutations)
- `scene.view_context`: Sibling component patterns at each insertion point
- `scene.existing_patterns`: Similar well-designed components in the codebase
- `modifications[]`: Per-claim convergence results — each entry has `claim_quote`, `reasoning` (as_is → to_be → divergence → divergence_layer), `intervention` (point, layer, aspect, classification, change_description, affected_components, prerequisite_changes), and `fidelity_check` (verification that the proposed change matches the literal claim)
- `feasibility.overall_feasibility`: Option set of all classifications present (e.g., `["view_only", "model_change_required"]`)
- `feasibility.model_changes_summary`: Summary of required model changes, or null

**Feature issues** (`issue_type == "feature"`):

- `scene.scene_description`: What the trace reveals about the existing scene
- `scene.owner_component`: The component that owns the scene
- `scene.child_components`: Components active in the scene (with trace evidence)
- `scene.data_model`: Data types available in the scene (with `api_surface`)
- `scene.data_pipeline`: How data flows through the current scene (trace-verified)
- `scene.view_context`: Sibling component patterns at each insertion point
- `scene.existing_patterns`: Similar features to follow as templates
- `integration.capabilities[]`: Per-capability convergence results — each entry has `claim_quote`, `reasoning` (as_is_infrastructure → to_be_requirement → gap → gap_layer), `integration_point` (UI insertion, data model changes, API requirements), `classification`, `layer`, `aspect`, and `prerequisite_changes`
- `feasibility.overall_readiness`: Option set of all classifications present (e.g., `["existing_infra", "extend_infra"]`)
- `feasibility.infra_changes_summary`: Summary of required infrastructure changes, or null
- `complexity`: Implementation scope assessment

Read the source code at each component location across all issues.

Build a **unified component inventory** — a merged list of all components, state types, data pipelines, view contexts, and existing patterns across all issues. For each entry, record which issue(s) reference it.

## Step 2: Cross-Issue Overlap Detection

Before designing any individual fix, compute which components, files, and state types are touched by multiple issues.

For each component/file/state type that appears in more than one issue's analysis:

> - Location: [file:line or type name]
> - Touched by: [ISS-XXX (type), ISS-YYY (type)]
> - Overlap classification: [complementary / conflicting / sequential]
> - Description: [what each issue wants to do with this component]

**Overlap classifications:**

- `complementary` — changes from different issues reinforce each other (e.g., both need the same model extension)
- `conflicting` — changes compete (e.g., bug fix removes a field the feature needs)
- `sequential` — one issue's change **MUST** land before another's can proceed

Set $OVERLAP_MAP to the list of overlapping entries.

If no overlaps exist (single issue, or issues touch completely different components), set $OVERLAP_MAP to empty and proceed.

## Step 3: Type-Dispatched Design

For EACH issue, execute the design methodology matching its `issue_type`. The overlap map from Step 2 is available to all sub-sections — reference it when designing changes to shared components.

### Step 3-Bug: Bug Fix Design

For each issue where `issue_type == "bug"`:

**Cross-issue awareness**: Check $OVERLAP_MAP. If any component being fixed is also modified by another issue, note the interaction and design the fix to be compatible with the other issue's changes.

#### 3-Bug.2a. Categorize the problem

Read the source code at every root cause site. Then:

> **Origin:** Is the unwanted state CREATED at the root cause site or LEAKED to the wrong consumer?
> Answer: [created / leaked / both]
>
> **Context:** Is the behavior ALWAYS wrong, or only wrong in the triggering context?
> Answer: [always / context-dependent]
>
> **Staleness:** Are there in-flight async operations that could emit state AFTER the fix takes effect?
> Answer: [yes / no]
>
> **Necessity:** Does the triggering context always require a full teardown-reconnect cycle? Or can it be short-circuited?
> Answer: [always required / can short-circuit when: ...]

These are LAYERS, not alternatives. A complete fix addresses ALL applicable layers. When a layer is categorized as applicable, every change addressing that layer is **required** — never label layer-addressing changes as "optional" or "hardening."

#### 3-Bug.2b. Enumerate all callers

Search the source for ALL call sites of the defective function — not just the one observed in the trace. For each caller:

> - Caller 1: [file:line] — [context: when does this caller invoke the defective function?]
> - Caller 2: [file:line] — [context]

For each caller, trace the arguments it passes. If an argument comes from a computed property or conditional expression, read that property's implementation — silent value transformations are a common source of redundant or incorrect invocations.

Verify your fix covers ALL callers, not just the observed one.

#### 3-Bug.3. Enumerate all state-emitting paths

Use `state_emissions.txt` as your starting checklist. For each path:

> - Path 1: [function:line] — sets [value] — guard: `[exact boolean expression]`
> - Path 2: [function:line] — sets [value] — guard: "unguarded"

For each guarded path, test sufficiency:

> "Can a cancelled/stale task bypass this guard? Describe the scenario where the guard evaluates to true despite the operation being stale."

For each unguarded path:

> "Does my fix guard this path? If no, this path MUST be addressed."

If any path is unguarded and unaddressed, your fix is incomplete.

#### 3-Bug.4. Design the fix

Address every insufficient path from 3-Bug.3, at every applicable layer from 3-Bug.2a.

- **created** → change the function so the unwanted value is never emitted. If callers need different behavior, split the function (e.g., public disconnect vs private cleanup).
- **leaked** → add filtering at the consumer. You need this EVEN IF you fixed the source, because stale async tasks may emit through the old path.
- **staleness = yes** → ensure every async path checks for staleness before emitting state. Prefer structural invalidation (generation counters) over mutable flags that can race.
- **can short-circuit** → add early return before the mechanism. Check ALL callers from 3-Bug.2b — if any caller passes derived values that could trigger redundant invocations, guard against that.

Every change **MUST** be labeled **required**. Do NOT label any change as "optional", "hardening", "defense-in-depth", or "nice-to-have." If the categorization says a layer is applicable, the fix for that layer is mandatory.

Draw before/after architecture AND algorithm diagrams:

```markdown
## Architecture

**Before:**
<!-- ASCII art diagram before changes -->

**After:**
<!-- ASCII art diagram after changes -->
```

```markdown
## Algorithms

**Before:**
<!-- ASCII art or code before changes -->

**After:**
<!-- ASCII art or code after changes -->
```

List specific code changes with rationale.
Include test cases.
State at least one alternative considered and why rejected.

#### 3-Bug.5. Validate against evidence

##### 5a. Mental execution trace

Mentally execute one full cycle of the triggering context after the fix is applied.

For each async operation cancelled by the fix:

> "What happens to [task name]? After the fix, it [description]. Does it emit state? If yes, is that emission correct or stale?"

##### 5b. Cross-reference state_emissions.txt

For EACH path in state_emissions.txt:

> Path N: [guarded/unguarded] — addressed by [which code change], or UNADDRESSED

If any path is UNADDRESSED, go back to 3-Bug.4.

##### 5c. Cross-reference caller enumeration

For EACH caller from 3-Bug.2b:

> Caller N: [file:line] — fix prevents symptom from this caller? [yes/no + why]

If any caller is not covered, go back to 3-Bug.4.

**CRITICAL**: If 3-Bug.5 reveals an unresolvable concern requiring trace data investigation, this bug issue returns `{"status": "needs_reinvestigation"}` for THIS issue only. Other issues in the session continue to be planned.

### Step 3-Improvement: Improvement Design

For each issue where `issue_type == "improvement"`:

**Cross-issue awareness**: Check $OVERLAP_MAP. If the feasibility gate requires model changes that overlap with a bug fix or feature's changes, reference the shared change instead of designing it twice.

#### 3-Improvement.2. Understand the current state

Read the source code at each component location from the analysis.

For each component, document:

> - Component: [name] at [file:line]
> - What it renders: [visual output]
> - What state drives it: [state type and property]
> - How the user interacts with it: [interaction flow]

Build a **current UX flow** — the sequence of states and transitions the user goes through today:

```markdown
## Current UX Flow

[State A] → (user action) → [State B] → (system response) → [State C]
```

#### 3-Improvement.2-Addendum. Map sibling visual context

If `view_context` is present in the analysis JSON:

For each entry in `view_context`, read the full enclosing view file and verify the sibling patterns documented by the analyzer. For each traced component that will be modified:

> - Enclosing file: [file path]
> - Parent layout: [layout container and configuration]
> - Sibling pattern: [how surrounding components are structured]
> - Styling conventions: [fonts, colors, spacing used by siblings]
> - Consistency requirement: [what the new/modified component must match]

If `view_context` is absent (older analysis data), read the `file` path from each entry in `components` and scan the full file to identify sibling patterns manually.

This context is required input for 3-Improvement.3a — every change design **MUST** account for it.

#### 3-Improvement.2.5. Architectural feasibility gate

Read `modifications[]` and `feasibility` from the analysis JSON.

Each entry in `modifications[]` contains a `reasoning` chain (as_is → to_be → divergence → divergence_layer) that explains WHY the classification was reached, an `intervention` describing WHAT to change, and a `fidelity_check` confirming the change matches the user's claim. Use these directly — do not reinterpret.

You **MUST** address every classification in `feasibility.overall_feasibility`:

**If `model_change_required` is present:**

Design model-layer changes for every `modifications[]` entry with that classification:

1. For each modification classified as `model_change_required`, read its `reasoning.divergence` (the specific gap between current and desired behavior) and `reasoning.divergence_layer` (which layer). Use `reasoning.to_be` as the design target.
2. Design the model-layer changes needed to unblock the view changes:
   > - Model change: [description]
   > - Affected type: [type name] at [file:line]
   > - Current API surface: [existing properties/methods]
   > - New API surface: [what needs to be added or restructured]
   > - Rationale: [which architectural constraint this resolves]

**If `new_capability_required` is present:**

Design new types or APIs for every entry with that classification:

   > - New type/API: [name and purpose]
   > - Interface: [type signature or protocol]
   > - Consumers: [which existing or new components will use it]

**If only `view_only` is present:**

Skip this step — all changes can be made at the view layer.

**Principle:** Every classification in the set **MUST** be addressed. You **MUST NOT** skip a classification or substitute a workaround from a lower classification level. Model and infrastructure changes **MUST** appear in the task list before view-layer tasks.

#### 3-Improvement.3. Design the improvement

##### 3a. Design each change

For each modification (from `modifications[]` in the analysis), using `reasoning.to_be` as the design target and `intervention.change_description` as the approach:

> - Change: [description]
> - Affected components: [list with file:line]
> - Change type: [modify / create / remove]
> - Implementation approach: [how to implement]
> - Pattern reference: [existing pattern from analysis to follow, if applicable]

If `scene.existing_patterns` is present in the analysis, check whether any pattern applies to this change. When a pattern applies, describe how the implementation should mirror it — reuse the same structural approach, naming conventions, or data flow mechanism that makes the pattern work well.

Diagrams are produced in the plan output's Solution section (see Output), not here. Step 3 focuses on design decisions; the output format handles presentation.

### Step 3-Feature: Feature Design

For each issue where `issue_type == "feature"`:

**Cross-issue awareness**: Check $OVERLAP_MAP. If infrastructure changes overlap with model changes from improvements or bug fixes, reference shared changes instead of designing them twice.

#### 3-Feature.2. Formalize requirements

From the analysis, formalize each capability as a concrete requirement:

> - REQ-1: [capability description] — acceptance criteria: [how to verify]
> - REQ-2: [capability description] — acceptance criteria: [how to verify]

Identify dependencies between requirements:

> - REQ-2 depends on REQ-1 because [reason]

#### 3-Feature.2-Addendum. Map sibling visual context

If `view_context` is present in the analysis JSON:

For each entry in `view_context`, read the full enclosing view file and verify the sibling patterns documented by the analyzer. For each insertion point where new UI will be added:

> - Enclosing file: [file path]
> - Parent layout: [layout container and configuration]
> - Sibling pattern: [how surrounding components are structured]
> - Styling conventions: [fonts, colors, spacing used by siblings]
> - Consistency requirement: [what the new feature's UI must match]

If `view_context` is absent (older analysis data), read the `file` path from each entry in `integration.capabilities[].integration_point.ui_insertion` and scan the full file to identify sibling patterns manually.

This context is required input for 3-Feature.3b — every new component design **MUST** account for it.

#### 3-Feature.2.5. Infrastructure readiness gate

Read `integration.capabilities[]` and `feasibility` from the analysis JSON.

Each entry in `integration.capabilities[]` contains a `reasoning` chain (as_is_infrastructure → to_be_requirement → gap → gap_layer) that explains WHY the classification was reached, an `integration_point` describing WHERE to add the feature, and a `classification`. Use these directly — do not reinterpret.

You **MUST** address every classification in `feasibility.overall_readiness`:

**If `extend_infra` is present:**

Design infrastructure extensions for every `integration.capabilities[]` entry with that classification:

1. For each capability classified as `extend_infra`, read its `reasoning.gap` (what's missing) and `reasoning.gap_layer` (which layer). Use `reasoning.to_be_requirement` as the design target.
2. Design the infrastructure extensions needed:
   > - Infrastructure change: [description]
   > - Affected type: [type name] at [file:line]
   > - Current API surface: [existing properties/methods]
   > - New API surface: [what needs to be added or extended]
   > - Rationale: [which infrastructure constraint this resolves]

**If `new_infra` is present:**

Design new infrastructure for every entry with that classification:

   > - New infrastructure: [name and purpose]
   > - Interface: [type signature or protocol]
   > - Consumers: [which new or existing components will use it]

**If only `existing_infra` is present:**

Skip this step — all capabilities can be built on existing infrastructure.

**Principle:** Every classification in the set **MUST** be addressed. You **MUST NOT** skip a classification or substitute a workaround from a lower classification level. Infrastructure changes **MUST** appear in the task list before UI tasks.

#### 3-Feature.3. Design the architecture

##### 3a. Integration design

For each integration point from the analysis, design how the feature connects to the existing codebase:

> - Integration point: [component] at [file:line]
> - Connection: [how the new code connects — call, event, binding, protocol]
> - Changes to existing code: [what modifications are needed, if any]
> - Pattern reference: [existing pattern from analysis to follow, if applicable]

If `scene.existing_patterns` is present in the analysis, check whether any pattern applies to this integration point. When a pattern applies, describe how the implementation should mirror it.

##### 3b. New components

Design each new component the feature requires:

> - Component: [name]
> - Responsibility: [what it does]
> - Inputs: [data it receives]
> - Outputs: [data it produces / UI it renders]
> - Pattern followed: [existing pattern from analysis, or new pattern with justification]

##### 3c. Data model

Design any new data types, state, or storage:

> - Type: [name]
> - Fields: [list with types]
> - Persistence: [in-memory / disk / network]
> - Relationship to existing types: [extends / composes / independent]

Diagrams are produced in the plan output's Solution section (see Output), not here.

## Step 4: Produce the Plan Output

Merge all per-issue designs from Step 3 into a single coherent plan. Write the plan to `{{$PLAN_OUTPUT_PATH}}`.

**The plan output MUST strictly follow the rigid format defined below.** The plan MUST contain exactly the sections listed (Issues, Solution, Tasks, Risks, Tests, Open Questions) in that order. Do NOT add sections not defined in the format. Do NOT produce free-form prose outside the defined sections. Each section MUST follow its HTML comment-guarded format guidance.

If any bug issue's 3-Bug.5 reveals an unresolvable concern, return ONLY for that issue:

```json
{
  "status": "needs_reinvestigation",
  "concern": "[describe the concern]",
  "issue_id": "[which bug issue]",
  "fix_target": "[which fix target]"
}
```

Otherwise, produce the complete plan following this rigid format:

### Plan output format

```markdown
# Plan: [one-line summary]

## Issues

<!-- One row per issue. Analysis column links to the analysis.json file. -->

| ID | Type | Description | Analysis |
| -- | ---- | ----------- | -------- |
| ISS-001 | improvement | ... | `path/to/analysis.json` |

## Solution

<!-- Group all modifications by where they land in the codebase.
     The grouping granularity is dynamic — use the level that best
     organizes the changes for this codebase: subsystem, framework,
     component, class, struct, or file. Choose the granularity that
     makes each group's changes coherent and independently reviewable.

     If multiple issues modify the same group, merge their changes
     into one coherent design and add a Merge note explaining how
     they combine. -->

### [GroupName] (`path/to/file.ext`)

**Issues addressed:** ISS-001, ISS-003

**Current behavior:** [one paragraph]

**Modifications:**

- [change description] (ISS-001)
- [change description] (ISS-003)

**Merge note:** [how the changes from different issues combine.
Omit if only one issue touches this group.]

<!-- Use before/after diagram components to explain the change visually.
     These four diagram types are PERSPECTIVES on the same change, not
     mutually exclusive categories. Select the perspective(s) whose
     primary concern matches the most important aspect of THIS change.
     Not every group needs diagrams. -->

<!-- Architecture diagram — static component graph
     Primary concern: what exists and who talks to whom.
     Use when adding, removing, or rewiring components. -->

## Architecture

**Before:**
<!-- ASCII art: boxes for components, arrows for dependencies -->

**After:**
<!-- Same diagram. (+) new, (-) removed, (~) modified -->

<!-- Data-flow diagram — runtime path data travels
     Primary concern: where data reaches and what route it takes.
     Use when components stay the same but data reaches different
     destinations or travels a different route. -->

## Data-flow

**Before:**
<!-- ASCII art: boxes for state sources, arrows for data flow -->

**After:**
<!-- (+) new paths, (-) removed paths, (~) modified paths -->

<!-- Algorithm diagram — logic within a single component
     Primary concern: what a component decides or computes.
     Use when wiring stays the same but conditional guards,
     state machines, or decision rules change. -->

## Algorithm

**Before:**
<!-- Pseudocode or state machine -->

**After:**
<!-- Same with modifications highlighted -->

<!-- UX Flow diagram — user-perceived interaction sequence
     Primary concern: what the user experiences.
     Use when the interesting part is screens, navigation,
     or visible state changes. -->

## UI Presentation

**Before:**
<!-- UI presentation in ASCII art before the modifications -->

**After:**
<!-- UI presentation in ASCII art after the modifications -->

## UX Flow

**Before:**
<!-- Step-by-step user interaction flow -->

**After:**
<!-- Modified flow with new/changed steps highlighted -->

## Tasks

<!-- Ordered implementation tasks. Each task targets one group or a
     tightly coupled set of groups.
     Ordering rules:
     1. Model/infrastructure changes before view changes
     2. Bug fixes before improvements on the same component
     3. Each task references which issue(s) it addresses -->

1. **[Task description]** — addresses: ISS-XXX — files: `path`
2. ...

## Risks

<!-- One row per component that has external dependents. -->

| Component | Dependents | Impact |
| --------- | ---------- | ------ |
| ... | ... | none / needs update |

<!-- Bug-specific audits: for each bug issue, include state emission
     and caller enumeration checklists as compact tables. -->

| Bug | Audit | Path/Caller | Status |
| --- | ----- | ----------- | ------ |
| ISS-XXX | emission | Path 1: [guard] | addressed by Task N |
| ISS-XXX | caller | Caller 1: [file:line] | covered: [yes/no] |

## Tests

<!-- Normal testing approach. Design tests to reproduce issues where
     applicable. Note when human interaction is required and automated
     testing is not possible. -->

## Open Questions

<!-- Unresolved questions that need developer input before or during
     implementation. This section is always last. -->
```

Respond with:

```json
{
  "status": "complete",
  "plan_file_path": "{{$PLAN_OUTPUT_PATH}}"
}
```
