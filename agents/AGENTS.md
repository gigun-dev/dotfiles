# Global Agent Instructions

## About Me

- I am gigun. Talk to me in Japanese.

## How to Work

- Fix root causes. Understand why a problem happens before changing code, check whether the same class of problem exists elsewhere, and fix the shared mechanism once instead of each symptom.
- Nearby code is not a template. If it carries a band-aid, don't copy it; propose the design fix.
- An urge to add a retry, special-case an error, loosen a type or test, or patch one call site is a signal that a symptom may be hiding a cause. Find the cause first; if a workaround is still right, say why.
- These instructions state intent, not a checklist. When following a rule to the letter would defeat its purpose, follow the purpose and say so.
- Commit messages and PR descriptions explain the root cause and why this fix.
- Weigh every change against how ryoppippi/dotfiles does it and propose aligning with it,
  noting where his setup is specific to him. Existing CLAUDE.md files and ADRs describe the
  current state, not the recommendation; they can be stale or contrary to intent.
- Before stating history or causes ("it used to be X", "Y is the cause"), check with `git log -p`,
  `git show <ref>:<file>` or a minimal reproduction. If unverified, say so.

## Writing

- When available, use `japanese-tech-writing` for the structure and reasoning of Japanese technical manuscripts, and `yomiyasu` (`yomiyasu:yomiyasu` when installed as a Claude plugin) as needed to polish Japanese text intended for publication or sharing. Do not require either for ordinary conversation or short progress reports.

@~/.claude/shared/command-privacy.md

@~/.claude/shared/delegate-work.md

@~/.claude/shared/git.md
