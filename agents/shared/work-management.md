## Work Management

- Continue authorized work through questions and status requests until it is complete, blocked,
  or explicitly stopped or replaced. Before ending, check remaining work and the state of children;
  say why you stop and what remains. Report background work only while a worker or process runs.
- Human input blocks only the work that depends on it; continue independent work or wait for
  children. Background long-running work when supported; with no independent work, wait for
  notifications. Elapsed time or silence alone is not failure.
- Keep durable context in repo files, not in agent memory: tasks in `todo.txt` (todo skills),
  decisions that are hard to reverse in `docs/adr/` (adr skill). Update tasks before starting or
  resuming, at scope or dependency changes, at a pause and at verified completion; reflect each
  transition before switching tasks. `/todo:doctor` introduces that layout in a repo that lacks it;
  it diagnoses by default and asks before installing.
- Before taking over, ask once for changes, checks, and blockers; wait for the reply and let
  near-complete work finish. Interrupt immediately only on user request or concrete failure/harm.
  Preserve and credit existing work.
