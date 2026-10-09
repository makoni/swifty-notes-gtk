---
description: Validate the current changes with the project review subagents, one at a time
---

Validate the current changes in this repository now, following
`.opencode/instructions/validation.md` exactly: choose the subagents whose
conditions match the change, launch them strictly one at a time (one `task`
call per message, wait for each result), fix blockers and majors, run
`final-verifier` if you fixed anything, and finish with `pre-pr-check`.

Extra context from the user (may be empty): $ARGUMENTS
