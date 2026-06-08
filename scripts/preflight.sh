#!/bin/bash
#
# preflight.sh — fast local pre-push gate for hermes-desktop.
#
# Runs the subset of the macOS CI pipeline that is reproducible on a
# Command-Line-Tools-only machine, so the common failure classes are caught
# BEFORE a push triggers a red run (and a failure email).
#
# WHAT THIS CATCHES:
#   1. Compile errors            — `swift build` (host arch).
#   2. Missing localization keys — replicates LocalizationCoverageTests'
#                                  directL10nKeys + table-sync checks in Python.
#
# WHAT THIS CANNOT CATCH (CI is the only authority — see docs/CI.md):
#   - macos-15-toolchain-only errors. Local Swift (Xcode 26 / 6.3.x) is NEWER
#     and MORE LENIENT than the CI runner's Swift; e.g. region-based isolation
#     accepts non-Sendable returns that the CI compiler rejects.
#   - The actual swift-testing run. CLT cannot load lib_TestingInterop.dylib,
#     so `swift test` never executes locally without full Xcode.
#
# => A change is only "passing" when the macOS CI run on its pushed SHA is green.
#    Confirm with:  gh run watch <run-id> --repo pcvelz/hermes-desktop
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail=0

echo "==> [1/2] swift build (host arch)"
if env SDKROOT="$(xcrun --show-sdk-path)" swift build --scratch-path .build-preflight >/tmp/preflight-build.log 2>&1; then
    echo "    OK — compiles"
else
    echo "    FAIL — compile errors:"
    grep -E "error:" /tmp/preflight-build.log | grep -vi "warning:" | sort -u | sed 's/^/      /' | head -20
    fail=1
fi

echo "==> [2/2] localization key coverage (mirrors LocalizationCoverageTests)"
python3 - <<'PY' || fail=1
import re, glob, sys
pat = re.compile(r'L10n\.string\(\s*"((?:\\.|[^"\\])*)"')
keys = set()
for f in glob.glob('Sources/HermesDesktop/**/*.swift', recursive=True):
    for m in pat.finditer(open(f, encoding='utf-8').read()):
        keys.add(m.group(1))
def table(loc):
    s = open(f'Sources/HermesDesktop/Resources/{loc}.lproj/Localizable.strings', encoding='utf-8').read()
    return set(re.findall(r'^"((?:\\.|[^"\\])*)"\s*=', s, re.M))
en = table('en')
missing = sorted(k for k in keys if k not in en)
problems = []
if missing:
    problems.append("    Missing English keys for L10n.string():")
    problems += [f"      - {k}" for k in missing]
for loc in ('zh-Hans', 'ru'):
    diff = sorted(en ^ table(loc))
    if diff:
        problems.append(f"    {loc} key set differs from en ({len(diff)} keys):")
        problems += [f"      - {k}" for k in diff[:10]]
if problems:
    print("    FAIL —")
    print("\n".join(problems))
    sys.exit(1)
print("    OK — all direct L10n keys present; en/zh-Hans/ru key sets in sync")
PY

echo
if [[ $fail -eq 0 ]]; then
    echo "PREFLIGHT PASSED (local). Reminder: only the macos-15 CI run is authoritative."
    echo "After pushing:  gh run watch \$(gh run list --repo pcvelz/hermes-desktop -L1 --json databaseId --jq '.[0].databaseId') --repo pcvelz/hermes-desktop"
else
    echo "PREFLIGHT FAILED — fix the above before pushing."
    exit 1
fi
