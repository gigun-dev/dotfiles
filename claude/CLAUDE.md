# Global conventions

Only what differs from the agent's own defaults belongs here.

- Delegate implementation to a subagent; the main thread designs and reviews.
- For another repository, use `cross-repo-implementer` with its absolute target
  checkout and exclusive writing ownership; do not create a worktree in the caller's
  repository. Use a separate target checkout if another writer is active there.
- Keep durable context in repo files, not in agent memory: tasks in `todo.txt`
  (todo skills), decisions that are hard to reverse in `docs/adr/` (adr skill).
  `/todo:doctor` introduces that layout in a repo that lacks it; it diagnoses by
  default and asks before installing.
- Run anything that makes the user wait in the background and keep working: test
  suites, builds, and `git push` (a pre-push hook can run the whole suite again).
  Say the expected wait as a number, never as "shortly".
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
