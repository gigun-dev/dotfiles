# Global conventions

Only what differs from the agent's own defaults belongs here.

- Delegate implementation to a subagent; the main thread designs and reviews.
- Keep durable context in repo files (`docs/next-directions.md`), not in agent memory.
  `/harness:doctor` introduces that layout in a repo that lacks it; it diagnoses by
  default and asks before installing.
