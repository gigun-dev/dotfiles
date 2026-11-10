## Secrets and Sensitive Metadata

- Never put a secret in command text, arguments, URLs, headers, inline environment assignments,
  heredocs, config snippets, prompts, or delegate briefs. Use an approved secret mechanism, a
  private file or file descriptor, or standard input, and keep the receiving process and lifetime
  narrowly scoped.
- Never print, log, quote, summarise, paste, commit, or forward a secret through tool results or
  child reports. Before calling a command, API, or tool that can return secrets or sensitive
  metadata, request only the required fields or filter at the source. Redacting after the call does
  not remove an already recorded tool result.
- Do not disclose credential identifiers, public keys, fingerprints, authentication URLs or codes,
  internal hosts or addresses, or exact secret-storage locations unless the task requires that
  specific value. Report purpose, credential class, state, owner type, permission boundary, and
  next action instead.
- Delegate with references and value-free metadata only. Tell children not to read or report actual
  values, and require decisions, verification state, and remaining actions without raw output.
- If an actual credential is exposed, stop repeating it, identify only its class and exposure
  channel, and treat revocation or rotation as required; deleting logs is not sufficient. Assess
  sensitive metadata exposure separately: it does not automatically require key rotation.
- Never ask for, collect, or store the macOS login password, even through a secret card or file
  delivery: a stored copy outlives the one command that needed it. On macOS, `sudo` authenticates
  with Touch ID, so run the `sudo` command directly and tell the user a Touch ID prompt is coming.
  If Touch ID is unavailable, hand the exact command to the user instead.
- Use public fixtures, dry runs, or disposable resources for tests. Production secrets and private
  data are not test fixtures.
