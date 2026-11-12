#!/bin/bash
# foamy-clock's own tests; tests/validate.sh runs this after the linters.
#   --ci    no Quickshell, no Omarchy host: node and the helper's Python tests
#   --fast  skip the offscreen runtime tests
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1
ci=0 fast=0
for arg in "$@"; do
  case $arg in
    --ci) ci=1 ;;
    --fast) fast=1 ;;
    *)
      echo "suite.sh: unknown argument $arg" >&2
      exit 2
      ;;
  esac
done
# validate.sh passes FOAMY_KIT; run alone, use the usual checkout.
export FOAMY_KIT="${FOAMY_KIT:-$HOME/GitHub/Personal/foamy-kit}"
status=0
run() {
  echo "== $*"
  "$@" || status=1
}
skip() { echo "SKIP $*"; }
for test in tests/*-test.js tests/i18n.test.cjs; do
  run node "$test"
done
run python3 -I -m unittest discover -s tests -p 'test_*.py'
if ((ci || fast)); then
  skip "tests/runtime.py and the kit's i18n_runtime.py: offscreen Quickshell on the 4.5 shell"
else
  run python3 -I tests/runtime.py
  run python3 -I "$FOAMY_KIT/preview/i18n_runtime.py" .
fi
exit $status
