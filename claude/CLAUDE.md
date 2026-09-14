# Global conventions

Only what differs from the agent's own defaults belongs here.

- Delegate implementation to a subagent; the main thread designs and reviews.
- Define each child assignment with bounded scope, relevant evidence, and explicit
  stop/completion criteria.
- For another repository, use `cross-repo-implementer` with its absolute target
  checkout and exclusive writing ownership; do not create a worktree in the caller's
  repository. Use a separate target checkout if another writer is active there.
- Reuse the same child for related follow-up work; preserve context and avoid duplicate
  assignments.
- Use the team's collaboration channel for child messages and reports; report only
  completion, blocker, decision, or new material evidence.
- Keep durable context in repo files, not in agent memory: tasks in `todo.txt`
  (todo skills), decisions that are hard to reverse in `docs/adr/` (adr skill).
  `/todo:doctor` introduces that layout in a repo that lacks it; it diagnoses by
  default and asks before installing.
- Run work that makes the user wait in the background when supported. While it runs,
  do only necessary independent work; otherwise wait for notifications. Progress
  updates do not require extra inspection.
- Use an observed estimate when available; never invent a numeric ETA.
- Elapsed time, silence, or a wait timeout alone never justifies interrupting or taking
  over a child.
- Before a nonurgent takeover, request one concise handoff with changed files,
  validation state, and blocker; wait for the reply and let the child finish near-complete
  work unless a concrete blocker prevents it. Preserve existing work when ownership changes.
- Interrupt immediately only for an explicit user request, concrete harmful or conflicting
  edits, or a confirmed failure that prevents continuation. Explain the evidence and distinguish inherited
  implementation from the parent's verification.
- Write Codex task text with the file-writing tool and pass its quoted path with
  `codex-companion.mjs task --prompt-file`; preserve Markdown and shell metacharacters.
  For direct `codex exec -`, redirect that file to stdin. Never interpolate task text
  into a shell command, including JSON strings inside double quotes.
- Assign children targeted checks and run the integrated full suite once in the parent.
  Schedule at most one heavy build or suite at a time among agents sharing a host;
  background execution does not add a slot. Repeat only for changed inputs, failures,
  or unresolved concerns. Required CI and pre-push checks still run.
- Before closing delegated work, reconcile its reported task/ADR candidates and
  required ignored artifacts in the main checkout; record unresolved items in todo.txt.
