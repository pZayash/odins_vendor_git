---
name: git-summarize-and-commit
description: Handles semantic summarization and committing of staged changes
alwaysApply: false
globs:
  - "**/*"
triggers:
  - "git summarize and commit"
  - "/git-summarize-and-commit"
---

# Git Semantic Summarize and Commit

The purpose of this command is to summarize and store for future analysis changes in the main
codebase of this project - 1C config dump, stored in `conf/`. Analysis is needed only for code
diffs and should not include changes in documentation, specs, **OpenSpec artifacts** (everything
under `openspec/`: proposals, change specs, tasks, archived changes, `openspec/config.yaml`, and
related files), AI rules and service scripts, unless the user explicitly asks to include those
categories.

## Workflow Steps

When the user requests to summarize and commit staged changes, follow these steps sequentially:

### Step 1. Check Staged Changes

Run `git diff --staged --name-only` to get the list of staged files.

> **RTK output warning**: this project uses `rtk` CLI proxy which prepends its own summary line
> and appends `--- Changes ---` section. The file list appears BEFORE `--- Changes ---`.
> If the output looks like this — files ARE staged, do not add anything:
>
> ```text
> conf/DataProcessors/SomeModule.bsl
> conf/Documents/SomeDoc.bsl
> --- Changes ---
> ```
>
> Only if the output contains NO file paths before `--- Changes ---` — nothing is staged yet.

**If files are staged:** do not touch the staging area at all, proceed to next step.

**If nothing is staged** (and the agent will stage files itself): inspect the working tree
(`git status`, `git diff`, optionally `git diff --name-only`) and **split** all pending changes
into **logically coherent parts** — for example by feature, bugfix vs refactor, subsystem, a
related set of modules, or separate OpenSpec/docs vs `conf/`. Do **not** lump unrelated
changes into one commit.

For **each** part, in order:

1. Stage **only** the files for that part: `git add` (or selective add) so the index contains one
   logical batch and nothing else from other parts remains staged.
2. Run **Steps 2–6** below for that batch: fresh `{TIMESTAMP}` per part, separate semantic summary
   file in `git-commit-summary/` per part (when Step 3–4 apply), and **one commit** per part.
3. After each commit, stage the next part’s files and repeat until every intended change is
   committed (or the user’s scope is done).

If the user already staged a **mixed** set and asked to split, reset or move files between commits
only in ways that preserve their intent (prefer `git restore --staged` + partial add), then follow
the same per-part loop.

### Step 2. Generate {TIMESTAMP}

Get the current {TIMESTAMP} in format `YYYYMMDD_HHmmss`:

**Primary (Bash):**

```bash
date +"%Y%m%d_%H%M%S"
```

**Fallback (PowerShell):**

```powershell
powershell -Command "Get-Date -Format 'yyyyMMdd_HHmmss'"
```

Store the result for use in the next steps.

### Step 3. Generate Semantic Summary

Analyze the staged diffs (`git diff --staged -- conf/`) and generate a comprehensive markdown
summary in **Russian**. Include only files in `conf/`, ignore all other changed files and specs.

**OpenSpec:** do **not** describe or analyze paths under `openspec/` in this summary unless the
user explicitly requested inclusion of OpenSpec artifacts. If only OpenSpec (and no `conf/`) is
staged, either skip writing a semantic summary for Step 3–4 or produce a minimal note that the
batch had no `conf/` changes — do not fill the summary with OpenSpec content by default.

The summary should include:

- **Контекст**: why these changes are being made (business logic, bug fix, feature, refactoring)
- **Изменения**: high-level description of what files were modified and what was changed
- **Технические детали**: key implementation details, patterns used, dependencies affected
- **Изменения в UI/UX**: if any — mention them, users will need to be notified

The summary should be detailed enough for future AI agents to understand the semantic meaning.

**!important** Follow [markdown formatting rules](docs/ai/markdown-formatting.md).
**!important** Do not delete previous summaries.

### Step 4. Save Summary File

- Save summary to `git-commit-summary/{TIMESTAMP}_semantic-summary.md` using the `write` tool
- Stage the file: `git add git-commit-summary/`

### Step 5. Draft Commit Message

Draft a conventional commit message based on the summary:

- Format: `{type}: {message} {TIMESTAMP}`
- Types: `feat:`, `fix:`, `refactor:`, `chore:`
- Concise but descriptive

### Step 6. Execute Commit

```bash
git commit -m "your drafted message here"
```

Use a heredoc to pass multiline messages:

```bash
git commit -m "$(cat <<'EOF'
refactor: краткое описание 20260316_161429

- Деталь 1
- Деталь 2
EOF
)"
```
