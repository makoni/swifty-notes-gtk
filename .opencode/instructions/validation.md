# Validating finished work with the project subagents

This repository has review subagents (see `.opencode/agents/`). Use them to
validate your own work before you report a task as done.

## When to validate

Validate when the task changed code or build/packaging files — anything under
`Sources/`, `Tests/`, `scripts/`, `data/`, `po/`, `flatpak/`, `snap/`,
`packaging/`, `.github/workflows/`, or `Package.swift` — and you believe the
task is complete.

Skip validation when:
- nothing in the repository changed (questions, explanations, research);
- only documentation or comments changed — then run only `pre-pr-check`;
- the user explicitly says to skip it.

If user-visible strings changed, first do the translation steps from
`AGENTS.md` (extract, merge, translate, build locales), then validate.

## Hard rule: one subagent at a time

- Launch exactly ONE subagent per message. Never put two `task` calls in the
  same message, even if they look independent.
- Wait for that subagent's result and read it before you launch the next one.
- Do not run subagents in the background.

## Which subagents, in this order

Go down the list and launch only those whose condition matches the change:

1. `swift-reviewer` — any Swift file under `Sources/` changed.
2. `architecture-reviewer` — a file, type or target was added, code moved
   between `Services/`, `UI/` and `Storage/`, `Sources/CSpelling/shim.h` or
   `Package.swift` changed, or platform guards (`#if os(macOS)`) changed.
3. `test-reviewer` — anything under `Tests/` changed, or the task was a bug fix
   (a bug fix needs a regression test).
4. `security-reviewer` — note storage, the trash, workspace/settings files, the
   `swiftynotes cli` commands, URL or image loading, the update checker,
   markdown/HTML/Pango rendering of note content, shelling out, logging, or the
   Flatpak/Snap manifests changed.
5. `regression-hunter` — the task was a bug fix.

Then:

6. Fix every **blocker** and **major** finding. Fix **minor** findings when the
   fix is small and in scope; otherwise list them in your final report.
7. If you fixed anything, launch `final-verifier` with the numbered list of
   findings you addressed.
8. Launch `pre-pr-check` last, as the gate (build, tests, leftovers, platform
   guards). If it reports a FAIL, fix it and launch `pre-pr-check` again.

Do at most two fix-and-verify rounds. If findings remain after that, stop and
report them to the user instead of looping.

## What to tell each subagent

Subagents start with no context. In every `task` prompt include:

- one or two sentences on what the task was and why;
- that the base branch is `master` and the changes may be uncommitted, so they
  must review the working tree: `git status --short`, `git diff origin/master`
  (plus reading any untracked files), not only `git diff origin/master...HEAD`;
- the list of changed files;
- for `final-verifier`: the findings, numbered, and what you changed for each.

## Final report

When you report the task as done, add a short validation section: which
subagents ran, their verdicts, what you fixed, and anything left open.
