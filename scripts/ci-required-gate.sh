#!/bin/sh
# Decide whether the conditional Nix jobs collectively satisfy the required CI gate.
set -eu

case "${CI_EVENT_NAME:-}" in
  push | pull_request | workflow_dispatch) ;;
  *)
    echo "required gate: unsupported or missing event" >&2
    exit 1
    ;;
esac

for result in "${CI_CHANGES_RESULT:-}" "${CI_CHECK_RESULT:-}" "${CI_BUILD_RESULT:-}"; do
  case "$result" in
    success | failure | cancelled | skipped) ;;
    *)
      echo "required gate: missing or invalid job result" >&2
      exit 1
      ;;
  esac
done

if [ "$CI_CHANGES_RESULT" != success ]; then
  echo "required gate: change detection did not succeed" >&2
  exit 1
fi

if [ "$CI_EVENT_NAME" = workflow_dispatch ] || [ "${CI_NIX_CHANGED:-}" = true ]; then
  if [ "$CI_CHECK_RESULT" != success ] || [ "$CI_BUILD_RESULT" != success ]; then
    echo "required gate: required Nix validation did not succeed" >&2
    exit 1
  fi
  exit 0
fi

if [ "${CI_NIX_CHANGED:-}" != false ]; then
  echo "required gate: change detection produced no decision" >&2
  exit 1
fi

if [ "$CI_CHECK_RESULT" != skipped ] || [ "$CI_BUILD_RESULT" != skipped ]; then
  echo "required gate: non-Nix job state is inconsistent" >&2
  exit 1
fi
