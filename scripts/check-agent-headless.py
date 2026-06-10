#!/usr/bin/env python3
"""check-agent-headless.py — assert the Hermes agent will NOT open a browser
when spawned the way the Desktop control endpoint spawns it.

WHY THIS EXISTS
---------------
The Desktop control endpoint runs chat/RPC turns by spawning the agent as a
local subprocess: `/bin/sh -c "export HERMES_HOME=...; export PATH=...; hermes
chat ..."`. There is no user at a TTY and no SSH_* vars. The agent decides
whether to physically open a browser for OAuth flows from two predicates:

    agent.google_oauth._is_headless()   -> if False, webbrowser.open(auth_url)
    tools.mcp_oauth._can_open_browser() -> if True,  webbrowser.open(auth_url)

If the spawn env carries no headless signal, BOTH choose to open the user's
default browser (Firefox) mid-chat instead of returning the auth URL in the
reply. That is the "session opens popups instead of using the API" bug. The
fix is HERMES_HEADLESS=1 in the spawn env (SSHTransport.runLocal). This script
is the regression gate for that contract.

EXIT CODES
    0  agent is correctly headless (no browser will open)
    1  agent would open a browser  (the bug)
    2  could not import the agent (path/install problem)
"""
import os
import sys

AGENT_ROOT = os.environ.get(
    "HERMES_AGENT_ROOT",
    os.path.expanduser("~/.hermes/hermes-agent"),
)
sys.path.insert(0, AGENT_ROOT)


def main() -> int:
    try:
        from agent.google_oauth import _is_headless
        from tools.mcp_oauth import _can_open_browser
    except Exception as exc:  # pragma: no cover
        print(f"FAIL: could not import agent OAuth modules from {AGENT_ROOT}: {exc!r}")
        return 2

    headless = _is_headless()
    can_open = _can_open_browser()

    seen = {k: os.getenv(k) for k in
            ("HERMES_HEADLESS", "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY")
            if os.getenv(k)}
    print(f"env headless-signals present: {seen or '(none)'}")
    print(f"agent.google_oauth._is_headless()   = {headless}  "
          f"({'OK: paste-mode' if headless else 'BUG: opens browser'})")
    print(f"tools.mcp_oauth._can_open_browser() = {can_open}  "
          f"({'BUG: opens browser' if can_open else 'OK: no browser'})")

    ok = headless and not can_open
    print("RESULT:", "PASS — agent stays headless, no popup" if ok
          else "FAIL — agent would open a browser window")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
