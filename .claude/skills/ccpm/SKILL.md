---
name: ccpm
description: "CCPM - spec-driven project management: PRD → Epic → GitHub Issues → parallel agents → shipped code. Use this skill when the user is managing planned delivery work: writing a PRD, turning a PRD into an epic, breaking an epic into tasks, syncing that work to GitHub, starting implementation for a tracked issue, or asking for delivery status such as standups, blockers, or next work. Do not use for debugging code, writing tests, reviewing PRs, or standalone GitHub issue/PR operations without PRD, epic, task, or delivery-tracking context."
---

# CCPM - Claude Code Project Manager

A spec-driven development workflow: PRD → Cross-Review → Epic → Cross-Review → GitHub Issues → Cross-Review → Shipped Code.

## Core Philosophy

CCPM handles **project management**: requirements files, GitHub issue syncing, parallel work analysis, worktree coordination, and progress tracking.

**Implementation quality** (brainstorming, planning, TDD, verification, review, finishing) is handled by [Superpowers](https://github.com/automazeio/superpowers) — each agent launched by CCPM independently follows the full Superpowers workflow. CCPM tracks progress through these gates but does not re-implement them.

### What CCPM Does
- PRD and epic file management with structured frontmatter
- Task decomposition with dependency and parallelization metadata
- GitHub issue creation, syncing, and lifecycle management
- Parallel stream analysis (identifying work that can happen simultaneously)
- Git worktree setup and agent coordination rules
- Progress tracking, standup reports, status queries

### What Superpowers Does
- Brainstorming and requirements clarification (`superpowers:brainstorming`)
- Implementation planning with user approval (`superpowers:writing-plans`)
- Test-driven development (`superpowers:test-driven-development`)
- Verification before claiming completion (`superpowers:verification-before-completion`)
- Code review (`superpowers:requesting-code-review`)
- Branch finishing and merge strategy (`superpowers:finishing-a-development-branch`)

### Cross-Review Gates
At spec handoff points, CCPM invokes `copilot-cross-review` as a second opinion before proceeding:
- After PRD creation → before parsing to epic
- After epic creation → before task decomposition
- After task decomposition → before syncing to GitHub

## File Conventions

Before doing anything, read `references/conventions.md` for path standards, frontmatter schemas, and GitHub operation rules. These apply to all phases.

## The Five Phases

### 1. Plan — Capture requirements
**When**: User wants to define a new feature, product requirement, or scope of work.
**Read**: `references/plan.md`
**Covers**: Writing PRDs, cross-review, converting PRDs to technical epics, cross-review.

### 2. Structure — Break it down
**When**: An epic exists and needs to be decomposed into concrete tasks.
**Read**: `references/structure.md`
**Covers**: Epic decomposition into numbered task files with dependencies and parallelization, cross-review.

### 3. Sync — Push to GitHub
**When**: Local epic/tasks need to become GitHub issues, progress needs to be posted as comments, or a bug is found and needs a linked issue created.
**Read**: `references/sync.md`
**Covers**: Epic sync (epic + tasks → GitHub issues), issue sync (progress comments), closing issues/epics, bug reporting.

### 4. Execute — Coordinate implementation
**When**: User wants to start working on one or more GitHub issues.
**Read**: `references/execute.md`
**Covers**: Parallel stream analysis, worktree setup, launching agents that follow the Superpowers workflow, tracking gate progress, closing issues on completion.

### 5. Track — Know where things stand
**When**: User asks for status, standup report, what's blocked, what's next, or needs to validate state.
**Read**: `references/track.md`
**Covers**: Status, standup, search, in-progress, next priority, blocked items, validation.

---

## Script-First Rule

For deterministic operations — anything that reads and reports without needing reasoning — always run the bash script directly:

| What the user wants | Script to run |
|---|---|
| Project status | `bash references/scripts/status.sh` |
| Standup report | `bash references/scripts/standup.sh` |
| List all epics | `bash references/scripts/epic-list.sh` |
| Show epic details | `bash references/scripts/epic-show.sh <name>` |
| Epic status | `bash references/scripts/epic-status.sh <name>` |
| List PRDs | `bash references/scripts/prd-list.sh` |
| PRD status | `bash references/scripts/prd-status.sh` |
| Search issues/tasks | `bash references/scripts/search.sh <query>` |
| What's in progress | `bash references/scripts/in-progress.sh` |
| What's next | `bash references/scripts/next.sh` |
| What's blocked | `bash references/scripts/blocked.sh` |
| Validate project state | `bash references/scripts/validate.sh` |

Use the LLM for work that requires reasoning: writing PRDs, analyzing parallelism, launching agents, synthesizing updates.

---

## Quick Reference

```
Plan a feature:     "I want to build X" or "create a PRD for X"
Parse to epic:      "turn the X PRD into an epic"
Decompose:          "break down the X epic into tasks"
Sync to GitHub:     "push the X epic to GitHub"
Start an issue:     "start working on issue 42"
Check status:       "what's our status" / "standup"
What's next:        "what should I work on next"
Merge epic:         "merge the X epic"
Report a bug:       "found a bug in issue 42" / "testing issue 42 revealed X"
```

Cross-reviews happen automatically at each spec handoff. Implementation quality gates are handled by Superpowers agents launched during Execute.
