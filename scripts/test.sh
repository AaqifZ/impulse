#!/bin/zsh
# Build Impulse, then run every test runner and app self-test. Stops at the first failure.
# Add --bench to also run the UI benchmark.
set -euo pipefail
cd "${0:A:h:h}"

zsh scripts/build.sh >/dev/null
for runner in launcher-core-tests calculator-tests discovery-tests currency-tests; do
    ".build/release/$runner" | tail -1
done
# CLI contract: JSON types, not strings. Agents parse this output.
cli=.build/release/launcherctl
"$cli" calculate "2 + 2" | grep -q '"isError" : false' || { echo "FAIL launcherctl calculate: isError is not a JSON Boolean"; exit 1; }
"$cli" calculate "1 / 0" | grep -q '"isError" : true' || { echo "FAIL launcherctl calculate: error result is not a JSON Boolean"; exit 1; }
echo "PASS launcherctl JSON contract"
app=dist/Impulse.app/Contents/MacOS/Impulse
for check in integration icons config-watcher clipboard capture; do
    "$app" "--self-test-$check" | tail -1
done
if [[ "${1:-}" == "--bench" ]]; then
    "$app" --benchmark-ui
fi
echo "ALL PASS"
