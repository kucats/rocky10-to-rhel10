#!/usr/bin/env bash
# Syntax-check every shell file; run shellcheck too when it is installed.
set -euo pipefail
cd "$(dirname "$0")/.."
files=$(ls bin/* lib/*.sh lib/*/*.sh extras/ssh-legacy tools/*.sh)
rc=0
for f in $files; do
  case $(head -n1 "$f") in
    '#!/bin/sh'*) sh -n "$f" || rc=1 ;;
    *) bash -n "$f" || rc=1 ;;
  esac
done
echo "syntax: $([ $rc = 0 ] && echo ok || echo FAILED)"
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  shellcheck -x -s bash $files || rc=1
else
  echo "shellcheck not installed; skipped"
fi
exit $rc
