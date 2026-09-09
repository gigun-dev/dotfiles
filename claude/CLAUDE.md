# Global conventions

Only what differs from the agent's own defaults belongs here.

- Delegate implementation to a subagent; the main thread designs and reviews.
- Keep durable context in repo files, not in agent memory: tasks in `todo.txt`
  (todo skills), decisions that are hard to reverse in `docs/adr/` (adr skill).
  `/todo:doctor` introduces that layout in a repo that lacks it; it diagnoses by
  default and asks before installing.
- Run anything that makes the user wait in the background and keep working: test
  suites, builds, and `git push` (a pre-push hook can run the whole suite again).
  Say the expected wait as a number, never as "shortly".
