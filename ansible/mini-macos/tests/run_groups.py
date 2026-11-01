"""Run all fixtures or an explicit group; native modules use test_native_*.py."""
import sys
import unittest


def tests(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from tests(test)
        else:
            yield test


all_tests = list(tests(unittest.defaultTestLoader.discover("tests", pattern="test_*.py")))
portable = [test for test in all_tests if not test.__class__.__module__.startswith("test_native_")]
native = [test for test in all_tests if test.__class__.__module__.startswith("test_native_")]
if not portable or not native:
    raise SystemExit("Expected both portable and native fixture groups")
group = {"full": all_tests, "portable": portable, "native": native}[sys.argv[1]]
result = unittest.TextTestRunner(verbosity=1).run(unittest.TestSuite(group))
raise SystemExit(not result.wasSuccessful())
