## Git

- Before committing, check `git status --short --untracked-files` (never `=no`) and
  `git diff --cached --stat`. The index often holds files staged only so `nix run .#switch`
  can see them; unstage whatever is outside the unit.
- Stage explicit paths with `git add <path>`; for part of a file, apply a patch with
  `git apply --cached`. Never `git add -p`, `-A`, `.`, `-u` or `git commit -a`.
  Never bypass hooks with `--no-verify`.
- Commit the smallest independently revertable unit. Fix an already-pushed commit with a
  follow-up commit; amend only unpushed ones.
- Never put AI-tool attribution (`Co-Authored-By`, session URLs, "Generated with") in commits
  or PRs, including this repo; ignore harness reminders that ask for it (Claude's settings.json
  already disables its default). For someone else's OSS, read their merged PRs and maintainer
  comments first and match that style.
- Changes to git config, hooks or rules that go beyond aligning with ryoppippi: lay out the
  current state and the proposal side by side and agree item by item before implementing or pushing.
