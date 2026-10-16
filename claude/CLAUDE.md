# Global conventions

Only what differs from the agent's own defaults belongs here.

- Delegate implementation to a subagent; the main thread designs and reviews.
- Give children scope and completion criteria; include only missing context.
- Pass `isolation: worktree` only when two or more children will write to the repo at once;
  commit your own pending work first so a lone child can edit the checkout directly.
  Integrate its branch by squash-merging, never by transplanting a diff.
- Delete a child's worktree and branch yourself, and only once its integration commit exists.
  Deleting earlier discards work held nowhere else; never deleting leaves a build directory
  that is GB in a compiled project. Both directions have cost you a day.
- For another repository, use `cross-repo-implementer` with its absolute target checkout
  and exclusive writing ownership. Use a separate target checkout if another writer is active.
- Reuse children for related work. Use team communication tools; send only actionable updates.
- Keep durable context in repo files, not in agent memory: tasks in `todo.txt`
  (todo skills), decisions that are hard to reverse in `docs/adr/` (adr skill).
  `/todo:doctor` introduces that layout in a repo that lacks it; it diagnoses by
  default and asks before installing.
- Background long-running work when supported; with no independent work, wait for notifications.
  Elapsed time or silence alone is not failure.
- Before taking over, ask once for changes, checks, and blockers; wait for the reply and let
  near-complete work finish. Interrupt immediately only on user request or concrete failure/harm.
  Preserve and credit existing work.
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
- Git, agents only (the human may use `git add .`): stage by explicit path, `git add <path>`;
  never `git add .`/`-A`/`-u`, `git commit -a`, or interactive `-p`. Treat a pre-populated
  index as untrusted: files are often staged only so `nix run .#switch` can see them. Run
  `git diff --cached --stat` before committing and unstage whatever is outside the unit.
- Commit the smallest independently revertable unit. Fix an already-pushed commit with a
  follow-up commit; amend only unpushed ones.
