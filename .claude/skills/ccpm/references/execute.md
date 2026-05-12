# Execute — Coordinate Implementation with Superpowers

CCPM handles **project-level coordination**: analysis, worktree setup, agent dispatch, gate tracking, and GitHub closure.

**Implementation quality** is delegated to agents, which follow the Superpowers workflow internally. CCPM tracks progress through each gate but does not re-implement Superpowers discipline.

```
CCPM                          Agent (per stream)
─────                         ──────────────────
Issue Analysis ──────────►    
Worktree + Tracking setup     
Launch agent ──────────────►  superpowers:brainstorming
                              superpowers:writing-plans (user-approved)
                              superpowers:test-driven-development
                              superpowers:verification-before-completion
Track gate progress ◄───────  (reports after each gate)
                              superpowers:requesting-code-review
                              superpowers:finishing-a-development-branch
GitHub issue close ◄────────  (reports completion)
```

---

## Issue Analysis

**Trigger**: User wants to understand how to parallelize work on an issue.

### Preflight
- Find the local task file: check `.claude/epics/*/<N>.md` first, then search for `github:.*issues/<N>` in frontmatter.
- If not found: "❌ No local task for issue #<N>. Run a sync first."

### Process

Get issue details: `gh issue view <N> --json title,body,labels`

Read the local task file fully. Identify independent work streams:
- Which files will be created/modified?
- Which changes can happen simultaneously without conflict?
- What are the dependencies between changes?

**Common stream patterns:**
- Database: schema, migrations, models
- Service: business logic, data access
- API: endpoints, validation, middleware
- UI: components, pages, styles

Create `.claude/epics/<epic_name>/<N>-analysis.md`:

```markdown
---
issue: <N>
title: <title>
analyzed: <run: date -u +"%Y-%m-%dT%H:%M:%SZ">
estimated_hours: <total>
parallelization_factor: <1.0-5.0>
---

# Parallel Work Analysis: Issue #<N>

## Overview

## Parallel Streams

### Stream A: <Name>
**Scope**:
**Files**:
**Can Start**: immediately
**Estimated Hours**:
**Dependencies**: none

### Stream B: <Name>
**Scope**:
**Files**:
**Can Start**: after Stream A
**Dependencies**: Stream A

## Coordination Points
### Shared Files
### Sequential Requirements

## Conflict Risk Assessment

## Parallelization Strategy

## Expected Timeline
- With parallel execution: <max_stream_hours>h wall time
- Without: <sum_all_hours>h
- Efficiency gain: <pct>%
```

**Output**: "✅ Analysis complete for issue #<N> — N parallel streams identified. Ready to start? Say: start issue <N>"

---

## Starting an Issue

**Trigger**: User wants to begin work on a specific GitHub issue.

### Preflight
1. Verify issue exists and is open: `gh issue view <N> --json state,title,labels,body`
2. Find local task file (as above).
3. Check for analysis file: `.claude/epics/*/<N>-analysis.md` — if missing, run analysis first.
4. Verify epic worktree exists: `git worktree list | grep "epic-<name>"` — if not: "❌ No worktree. Sync the epic first."

### Process

**Step 1 — Read the analysis**, identify which streams can start immediately vs. which have dependencies.

**Step 2 — Create progress tracking:**
```bash
mkdir -p .claude/epics/<epic>/updates/<N>
current_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
```

Create `.claude/epics/<epic>/updates/<N>/stream-<X>.md` for each stream:
```markdown
---
issue: <N>
stream: <stream_name>
started: <datetime>
status: in_progress
---
## Superpowers Gate Progress
- [ ] Brainstorming (superpowers:brainstorming)
- [ ] Implementation Plan (superpowers:writing-plans — user-approved)
- [ ] TDD (superpowers:test-driven-development)
- [ ] Verification (superpowers:verification-before-completion)
- [ ] Code Review (superpowers:requesting-code-review)
- [ ] Finish (superpowers:finishing-a-development-branch)

## Notes
```

**Step 3 — Assign on GitHub:**
```bash
gh issue edit <N> --add-assignee @me --add-label "in-progress"
```

**Step 4 — Launch agents** for each stream that can start immediately. Each agent is responsible for its own Superpowers workflow:

```yaml
Task:
  description: "Issue #<N> Stream <X>"
  subagent_type: "general-purpose"
  prompt: |
    You are working on Issue #<N> in the epic worktree at: ../epic-<name>/

    Your stream: <stream_name>
    Your scope — files to modify: <file_patterns>
    Work to complete: <stream_description>

    ## REQUIRED: Superpowers Implementation Workflow

    You must follow the full Superpowers workflow. Do not skip any step.

    ### 1. Brainstorming
    Invoke superpowers:brainstorming for your stream.
    Clarify: what exactly are you building? edge cases? constraints?
    Document decisions in your stream progress file.

    ### 2. Implementation Plan
    Invoke superpowers:writing-plans based on the brainstorming output.
    Write a concrete plan covering files, interfaces, data flow, error handling.
    **You must get explicit user approval before writing any code.**
    Save the approved plan.

    ### 3. Test-Driven Development
    Invoke superpowers:test-driven-development.
    Write tests FIRST → watch them fail (RED) → write minimal implementation (GREEN) → refactor.
    No implementation code before tests exist and fail.

    ### 4. Verification
    Invoke superpowers:verification-before-completion.
    Run full test suite, linter, type checker, build.
    Verify acceptance criteria from the task file.
    Do NOT claim completion until all verification passes.

    ### 5. Code Review
    After your stream passes verification, request review.
    Invoke superpowers:requesting-code-review.
    Address all feedback before proceeding.

    ### 6. Finish
    After review passes, invoke superpowers:finishing-a-development-branch.
    Handle merge/PR/cleanup for your stream.

    ## CCPM Coordination Rules

    - Read the full task from: .claude/epics/<epic>/<N>.md
    - Read the analysis from: .claude/epics/<epic>/<N>-analysis.md
    - Work ONLY in your assigned files
    - Commit frequently: "Issue #<N>: <specific change>"
    - After EACH Superpowers gate, check the box in: .claude/epics/<epic>/updates/<N>/stream-<X>.md
    - If you need to touch files outside your scope, note it and wait
    - Never use --force on git operations
    - Before modifying a shared file, check git status — if another agent has it modified, wait and pull
    - Sync via: git pull --rebase origin epic/<name> before starting new file work
    - Conflicts are never auto-resolved — report them and pause
```

**Step 5 — Create execution status file** at `.claude/epics/<epic>/updates/<N>/execution.md`:
```markdown
## Active Streams
- Stream A: <name> — Started <time>
- Stream B: <name> — Started <time>

## Gate Progress
| Stream | Brainstorm | Plan | TDD | Verify | Review | Finish |
|--------|-----------|------|-----|--------|--------|--------|
| A | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| B | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |

## Completed
(none yet)
```

**Step 6 — Streams with unmet dependencies** are queued. Launch them as their dependencies complete.

**Output:**
```
✅ Started work on issue #<N>

Launched N agents (each follows Superpowers workflow independently):
  Stream A: <name> ✓ Started
  Stream B: <name> ⏸ Waiting (depends on A)

Agents will report progress after each Superpowers gate.
Monitor: .claude/epics/<epic>/updates/<N>/
```

---

## After All Streams Complete

When all streams for the issue have passed all 6 Superpowers gates:

1. **Close the GitHub issue** (from `references/sync.md` closing process):
   - Update task file frontmatter: `status: closed`
   - Post completion comment on the issue
   - Check off the task in the epic issue body
   - Recalculate epic progress

2. **If this was the last open issue in the epic**, clean up the worktree:
   ```bash
   cd ../epic-<name> && git push origin epic/<name>
   cd <main_repo> && git worktree remove ../epic-<name>
   ```

3. **Update execution status** to reflect completion.

---

## Starting a Full Epic

**Trigger**: User wants to launch work across all ready issues in an epic.

### Preflight
- Verify `.claude/epics/<name>/epic.md` exists and has a `github:` field.
- Check for uncommitted changes: `git status --porcelain` — block if dirty.
- Verify epic branch exists: `git branch -a | grep "epic/<name>"`

### Process

**Step 1 — Read all task files**. Parse frontmatter for `status`, `depends_on`, `parallel`.

**Step 2 — Categorize:**
- Ready: status=open, no unmet depends_on
- Blocked: has unmet depends_on
- In Progress: already has execution file
- Complete: status=closed

**Step 3 — Analyze any ready tasks** without an analysis file.

**Step 4 — Launch agents for all ready tasks** following the per-issue pattern above. Each agent independently follows the Superpowers workflow.

**Step 5 — Create/update** `.claude/epics/<name>/execution-status.md`.

**Step 6 — As agents complete**, unblock dependent tasks and launch their agents.

---

## Agent Coordination Rules

When multiple agents work in the same worktree simultaneously:

- Each agent works only on files in its assigned stream scope.
- Agents commit frequently with `Issue #<N>: <description>` format.
- Before modifying a shared file, check `git status <file>` — if another agent has it modified, wait and pull first.
- Agents sync via commits: `git pull --rebase origin epic/<name>` before starting new file work.
- Conflicts are never auto-resolved — agents report them and pause.
- No `--force` flags ever.

Shared files that commonly need coordination (types, config, package.json) should be handled by one designated stream; others pull after that commit.
