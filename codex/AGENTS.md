Always respond in Japanese

## Delegated work lifecycle

- Give each child a bounded scope, relevant evidence, explicit stop/completion criteria,
  and validation ownership.
- Reuse the same child for related follow-up work; preserve context and avoid duplicate
  assignments.
- Use `collaboration` tools for parent-child coordination and `collaboration.send_message`
  for reports; do not use Codex app task APIs or read the parent task history.
- Ask children to report only completion, blocker, decision, or new material evidence.
- If the parent has no independent work, wait for notifications; progress updates do not
  require extra inspection.
- Elapsed time, silence, or a wait timeout alone never justifies interrupting or taking
  over a child.
- Before a nonurgent takeover, request once a concise handoff with changed files,
  validation state, and blocker; wait for the reply and let the child finish near-complete
  work unless a concrete blocker prevents it. Preserve existing work when ownership changes.
  Interrupt immediately only for an explicit user request, concrete harmful or conflicting
  edits, or a confirmed failure that prevents continuation; explain the evidence and
  distinguish inherited implementation from the parent's verification.
