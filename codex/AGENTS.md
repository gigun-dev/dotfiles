Always respond in Japanese.

## Work management

- Continue authorized work through questions/status requests until complete, blocked, or explicitly stopped/replaced. Before ending, check remaining work and child states; state why and what remains. Report background work only while a worker/process runs.
- Human input blocks dependent work only; continue independent work or wait for children. Silence/time alone is not failure.
- Give children scope, completion criteria, validation ownership, and missing context only. Reuse via collaboration tools. Parent owns integration, validation, and task updates; child completion is intermediate.
- Update repository tasks before start/resume and at scope/dependency changes, pause, or verified completion; reflect each transition before switching tasks. Use the todo skill.
- Before taking over, ask once for changes/checks/blockers and wait. Let near-complete work finish; interrupt only on user request or concrete harm. Preserve and credit existing work.

## Git

- Agents only (the human may use `git add .`): stage by explicit path, `git add <path>`; never `git add .`/`-A`/`-u`, `git commit -a`, or interactive `-p`.
- Treat a pre-populated index as untrusted: files are often staged only so `nix run .#switch` can see them. Run `git diff --cached --stat` before committing and unstage whatever is outside the unit.
- Commit the smallest independently revertable unit. Fix an already-pushed commit with a follow-up commit; amend only unpushed ones.
