# Fix Plan Design

You are an expert software engineer designing a fix plan based on analysis results.

## Step 1: Read Analysis Data

Read the analysis session from the directory provided in the task prompt.

List `{{$ANALYSIS_SESSION_PATH}}/issues/` to find identified issues.

**For each issue of $ISSUE_ID, read ALL artifacts:**

1. `{{$ISSUE_ID}}/analysis.json` — defect summary, causal chain, state mutation map, architecture review, debugging strategies
2. `{{$ISSUE_ID}}/traces/causal_sequence.txt` — function call ordering and timing
3. `{{$ISSUE_ID}}/traces/state_emissions.txt` — every state-emitting path with exact guard expressions (your checklist for Step 3)
4. `{{$ISSUE_ID}}/architecture_review.md` — mechanism documentation and design opinions
5. `{{$ISSUE_ID}}/debugging_strategies.md` — strategy results including guard audit findings

Pay close attention to:
- **state_emissions.txt**: Every unguarded emission path is a potential fix target
- **architecture_review.md**: Design flaws identified here must be addressed, not worked around
- **debugging_strategies.md**: Guard audit results reveal existing mechanisms that are incomplete — extend them rather than adding new ones

## Step 2: Categorize and Enumerate

Read the source code at every root cause site. Then:

### 2a. Categorize the problem

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

### 2b. Enumerate all callers

Search the source for ALL call sites of the defective function — not just the one observed in the trace. For each caller:

> - Caller 1: [file:line] — [context: when does this caller invoke the defective function?]
> - Caller 2: [file:line] — [context]

For each caller, trace the arguments it passes. If an argument comes from a computed property or conditional expression, read that property's implementation — silent value transformations are a common source of redundant or incorrect invocations.

Verify your fix covers ALL callers, not just the observed one.

## Step 3: Enumerate All State-Emitting Paths

Use `state_emissions.txt` as your starting checklist. For each path:

> - Path 1: [function:line] — sets [value] — guard: `[exact boolean expression]`
> - Path 2: [function:line] — sets [value] — guard: "unguarded"

For each guarded path, test sufficiency:

> "Can a cancelled/stale task bypass this guard? Describe the scenario where the guard evaluates to true despite the operation being stale."

For each unguarded path:

> "Does my fix guard this path? If no, this path MUST be addressed."

If any path is unguarded and unaddressed, your fix is incomplete.

## Step 4: Design the Fix

Address every insufficient path from Step 3, at every applicable layer from Step 2.

- **created** → change the function so the unwanted value is never emitted. If callers need different behavior, split the function (e.g., public disconnect vs private cleanup).
- **leaked** → add filtering at the consumer. You need this EVEN IF you fixed the source, because stale async tasks may emit through the old path.
- **staleness = yes** → ensure every async path checks for staleness before emitting state. Prefer structural invalidation (generation counters) over mutable flags that can race.
- **can short-circuit** → add early return before the mechanism. Check ALL callers from Step 2b — if any caller passes derived values that could trigger redundant invocations, guard against that.

Every change must be labeled **required**. Do NOT label any change as "optional", "hardening", "defense-in-depth", or "nice-to-have." If the categorization says a layer is applicable, the fix for that layer is mandatory.

Draw before/after architecture or algorithm diagrams.
List specific code changes with rationale.
Include test cases.
State at least one alternative considered and why rejected.

## Step 5: Validate Against Evidence

### 5a. Mental execution trace

Mentally execute one full cycle of the triggering context after the fix is applied.

For each async operation cancelled by the fix:

> "What happens to [task name]? After the fix, it [description]. Does it emit state? If yes, is that emission correct or stale?"

### 5b. Cross-reference state_emissions.txt

For EACH path in state_emissions.txt:

> Path N: [guarded/unguarded] — addressed by [which code change], or UNADDRESSED

If any path is UNADDRESSED, go back to Step 4.

### 5c. Cross-reference caller enumeration

For EACH caller from Step 2b:

> Caller N: [file:line] — fix prevents symptom from this caller? [yes/no + why]

If any caller is not covered, go back to Step 4.

## Output

If Step 5 reveals an unresolvable concern requiring trace data investigation, return ONLY:

```json
{
  "status": "needs_reinvestigation",
  "concern": "[describe the concern]",
  "fix_target": "[which fix target]"
}
```

Otherwise, produce the complete fix plan and write it to `{{$PLAN_OUTPUT_PATH}}`.

The plan MUST include:

1. **Analysis data summary** (Step 1)
2. **Problem categorization** (Step 2a)
3. **Caller enumeration** (Step 2b)
4. **State emission audit** (Step 3)
5. **Fix design** (Step 4)
6. **Validation** (Step 5 — all three sub-steps)
7. **Test cases**
8. **Alternative considered** and why rejected

Present fix design with before/after diagrams:

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

Finally, respond with:

```json
{
  "status": "complete",
  "plan_file_path": "{{$PLAN_OUTPUT_PATH}}"
}
```
