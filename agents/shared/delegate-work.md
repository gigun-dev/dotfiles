## Delegating Work

- Hand work whose output is bulky but whose conclusion is small — web search, page reading,
  codebase investigation, summarising long output — to your own native subagent (the Agent tool
  in Claude Code, a native subagent in Codex). Keep here what needs this conversation's history.
- Delegate implementation only when the brief is cheaper than the work. Plan and split here; hand a
  well-specified step over with a self-contained brief (scope, files, intended change, how to verify,
  completion criteria, only the context it lacks), then check its diff. Match the model to the task;
  when doing it yourself is quicker than writing the brief, do it yourself.
- The brief says the child cannot ask the user and must not delegate further, and asks it to report
  its decisions with open questions, the checks it ran (commands, tested commit, results, unverified
  scope), task/ADR candidates, and ignored artifacts the parent needs. The parent owns integration,
  validation and task updates; a child's completion is intermediate. Reuse a child for related
  follow-up and send it only actionable updates.
- Never start a nested CLI of the agent you are running in. For another vendor's independent
  opinion or a review, use a strong model from another vendor (the `codex` plugin from Claude Code).
  Write Codex task text with the file-writing tool and pass its quoted path with
  `codex-companion.mjs task --prompt-file`, or redirect the file to `codex exec -`. Never interpolate
  task text into a shell command, including JSON strings inside double quotes: Markdown and shell
  metacharacters break.
- Give a child its own worktree (`isolation: worktree` in Claude Code) only when two or more children
  will write to the same repo at once; otherwise commit your own pending work first and let the lone
  child edit the checkout. Brief an isolated child to commit on its branch, run one simple command per
  call and use `git -C`: Claude Code's permission checker rejects compound commands from it because it
  cannot prove they stay inside the worktree. Integrate its branch by squash-merging, never by
  transplanting a diff.
- Delete a child's worktree and branch yourself, and only once its integration commit exists.
  Deleting earlier discards work held nowhere else; never deleting leaves a build directory
  that is GB in a compiled project. Both directions have cost you a day.
- For another repository, give the child the absolute target checkout and exclusive writing
  ownership of it; it must not create a worktree in the caller's repo. Use a separate target
  checkout if another writer is active.
- Children run targeted checks; the parent runs the integrated full suite once.
  Schedule at most one heavy build or suite at a time among agents sharing a host;
  background execution does not add a slot. Repeat only for changed inputs, failures,
  or unresolved concerns. Required CI and pre-push checks still run.
- Before closing delegated work, reconcile its reported task/ADR candidates and
  required ignored artifacts in the main checkout; record unresolved items in todo.txt.
