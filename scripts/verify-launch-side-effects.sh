#!/bin/bash
#
# verify-launch-side-effects.sh — runtime behaviour gate for Hermes Desktop.
#
# CI proves the app COMPILES and unit-tests pass. It does NOT prove the app
# BEHAVES when a chat session runs. A whole class of regressions is invisible
# to CI: side effects of a spawned agent turn — opening an external browser,
# auto-firing an OAuth/network flow. The failure of record (2026-06-10): a
# Desktop chat asking to read Gmail popped Firefox repeatedly because the
# control endpoint spawned the agent with no headless signal, so the agent's
# OAuth path opened a real browser instead of returning the auth URL.
#
# This gate has two layers:
#   1. CONTRACT (deterministic, no app needed): assert the agent stays headless
#      under the EXACT environment the control endpoint gives it. This is the
#      check that would have caught the bug, and it runs in <1s with no GUI.
#   2. EMPIRICAL (optional, --live): wrap a real command in a browser-window
#      before/after diff to catch any popup the contract check can't predict.
#
# USAGE
#   scripts/verify-launch-side-effects.sh            # contract layer only
#   scripts/verify-launch-side-effects.sh --live -- <cmd...>   # + window diff
#
# EXIT 0 = all layers pass.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME_DEFAULT="${HERMES_HOME:-$HOME/.hermes/profiles/coding}"
PATH_FOR_AGENT="${PATH_FOR_AGENT:-/opt/homebrew/bin:/usr/bin:/bin}"

fail() { echo "❌ $*" >&2; exit 1; }

echo "── Layer 1: agent-headless contract (Desktop control-endpoint spawn env)"
# Reproduce SSHTransport.runLocal's wrapper. The control endpoint MUST export
# HERMES_HEADLESS=1; we assert the agent honours it. Run with the SSH_* vars
# unset because a local /bin/sh spawn has none.
if /bin/sh -c '
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    export HERMES_HOME="'"$HERMES_HOME_DEFAULT"'"
    export PATH="'"$PATH_FOR_AGENT"'"
    export HERMES_HEADLESS=1
    exec python3 "'"$HERE"'/check-agent-headless.py"
'; then
    echo "✅ Layer 1 PASS"
else
    fail "Layer 1 FAIL — agent would open a browser under the Desktop spawn env.
   The control endpoint spawn (SSHTransport.runLocal) must export HERMES_HEADLESS=1,
   and the agent's OAuth predicates must honour it. See HERMES_DESKTOP.md."
fi

# Negative control: prove the gate actually catches the bug (without the flag).
echo "── Layer 1b: negative control (no HERMES_HEADLESS → MUST report the bug)"
if /bin/sh -c '
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY HERMES_HEADLESS
    export HERMES_HOME="'"$HERMES_HOME_DEFAULT"'"
    export PATH="'"$PATH_FOR_AGENT"'"
    exec python3 "'"$HERE"'/check-agent-headless.py"
' >/dev/null 2>&1; then
    fail "Negative control PASSED unexpectedly — the gate is not actually testing the
   browser predicate (it should FAIL when HERMES_HEADLESS is absent)."
else
    echo "✅ Layer 1b PASS — gate correctly flags the unguarded spawn as buggy"
fi

if [[ "${1:-}" == "--live" ]]; then
    shift; [[ "${1:-}" == "--" ]] && shift
    [[ $# -ge 1 ]] || fail "--live needs a command after --"
    echo "── Layer 2: empirical browser-window diff around: $*"
    count_browser_windows() {
        osascript -e '
          set n to 0
          repeat with appName in {"Firefox", "Safari", "Google Chrome", "Brave Browser"}
            try
              tell application "System Events"
                if exists (process appName) then
                  set n to n + (count of windows of process appName)
                end if
              end tell
            end try
          end repeat
          return n' 2>/dev/null || echo 0
    }
    before="$(count_browser_windows)"
    "$@" || true
    sleep 2
    after="$(count_browser_windows)"
    echo "browser windows: before=$before after=$after"
    [[ "$after" -le "$before" ]] || fail "Layer 2 FAIL — $((after - before)) new browser window(s) opened."
    echo "✅ Layer 2 PASS — no new browser windows"
fi

echo "🎉 verify-launch-side-effects: ALL LAYERS PASS"
