#!/usr/bin/env python3
"""Synthetic observations only: never contact a host or inspect credentials."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("context", Path(__file__).parents[1] / "execution-context.py")
context = importlib.util.module_from_spec(spec)
spec.loader.exec_module(context)


class ContextTests(unittest.TestCase):
    def evidence(self, result, execution="sandbox", probe="github-api", status=None):
        return context.record("pro", "github" if probe == "github-api" else "mini-vm", execution, probe, result, status)

    def test_sandbox_failures_are_not_authentication_revocation(self):
        for result in ("dns-unavailable", "transport-failed", "token-invalid-message", "permission-denied"):
            self.assertEqual(self.evidence(result)["assessment"], "context-limited-failure")
        self.assertEqual(self.evidence("http-response", status=401)["assessment"], "http-401-in-this-context")
        self.assertEqual(self.evidence("http-response", status=403)["assessment"], "http-403-in-this-context")

    def test_success_elsewhere_preserves_both_observations(self):
        failed = self.evidence("token-invalid-message")
        passed = self.evidence("http-response", "reviewed-read-only", status=200)
        self.assertEqual(failed["assessment"], "context-limited-failure")
        self.assertEqual(passed["assessment"], "succeeded-in-this-context")
        self.assertNotEqual(failed["context"], passed["context"])

    def test_real_policy_denial_is_stop_in_every_context(self):
        for execution in context.CONTEXTS:
            self.assertEqual(self.evidence("tailnet-policy-denied", execution, "ssh")["assessment"], "policy-denied-stop")

    def test_signature_failure_does_not_claim_artifact_invalid(self):
        for probe in ("codesign", "gatekeeper"):
            self.assertEqual(self.evidence("verification-failed", probe=probe)["assessment"], "context-limited-failure")
            self.assertEqual(self.evidence("verification-failed", "human-terminal", probe)["assessment"], "unconfirmed")

    def test_raw_output_and_invalid_http_cannot_be_recorded(self):
        for result, status in (("SECRET_TOKEN", None), ("http-response", None), ("success", 200), ("http-response", 999), ("http-response", True)):
            with self.assertRaises(ValueError):
                self.evidence(result, status=status)
        with self.assertRaises(ValueError):
            context.record("SECRET_HOST", "mini", "sandbox", "dns", "success")
        self.assertNotIn("SECRET", json.dumps(self.evidence("success")))


if __name__ == "__main__":
    unittest.main()
