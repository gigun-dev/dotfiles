---
name: blind-test-coder
description: Write independent black-box tests from a specification. Use when asked for blind testing, tests from the spec, or a separate agent to write failing tests for an implementer.
---

Use a tester who has not seen the implementation discussion. Give them the exact
revision, the public contract, the runnable entry point, and the paths where
they may add tests. Share runner setup separately from existing test assertions.
In T3 Code, use the t3-delegate skill and a separate checkout.

The tester derives expected behavior from the supplied spec, public docs, and
CLI help. Exercise the built product through its public interface. Keep the
existing suite in place and write the independent tests separately. Read neither
implementation source nor existing test assertions while designing the suite.
Use fixtures or isolated resources for operations that can change external state.

For each failure, report the contract reference, expected and actual behavior,
and the command to reproduce it. Flag ambiguous requirements and missing
environment prerequisites separately. Record which tests passed, failed, or
could not run. The tester changes test files only.

For a fix loop, the implementer takes the reproducible failures and changes
product code. Rerun the same independent suite on the updated revision. Change an
expectation only when the specification is clarified. Stop when the agreed
cases pass or a specification decision or environment prerequisite blocks them.

Workflow inspiration: https://github.com/laiso/agent-sessions/tree/main/skills/blind-test-coder
