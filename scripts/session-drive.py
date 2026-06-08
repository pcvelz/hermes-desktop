#!/usr/bin/env python3
"""Drive the Hermes Desktop control endpoint's terminal-session API.

  session-drive.py spawn [initial_input] [profile]   -> create a visible interactive tab, print its id
  session-drive.py write <id> <text...>              -> type a line (with Enter) into the session
  session-drive.py write-noenter <id> <text...>      -> type text without Enter (e.g. for a bare Enter, pass '')
  session-drive.py enter <id>                         -> send a bare Enter
"""
import json, os, sys, urllib.request, urllib.error

d = json.load(open(os.path.expanduser('~/.hermes-desktop/control.json')))
PORT, TOK = d['port'], d['token']
BASE = f"http://localhost:{PORT}"

def post(path, body):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(body).encode(),
        headers={'Content-Type': 'application/json', 'Authorization': f'Bearer {TOK}'},
        method='POST')
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def get(path):
    req = urllib.request.Request(BASE + path, headers={'Authorization': f'Bearer {TOK}'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

cmd = sys.argv[1] if len(sys.argv) > 1 else 'spawn'

if cmd == 'spawn':
    initial = sys.argv[2] if len(sys.argv) > 2 else 'herm-claude'
    profile = sys.argv[3] if len(sys.argv) > 3 else 'coding'
    sc, body = post('/terminal/session', {'profile': profile, 'initial_input': initial})
    print(f"HTTP {sc}")
    try:
        print("session_id:", json.loads(body).get('id'))
    except Exception:
        print(body[:300])

elif cmd in ('write', 'write-noenter'):
    sid = sys.argv[2]
    text = ' '.join(sys.argv[3:])
    sc, body = post(f'/terminal/session/{sid}/write',
                    {'input': text, 'enter': cmd == 'write'})
    print(f"HTTP {sc}: {body[:200]}")

elif cmd == 'enter':
    sid = sys.argv[2]
    sc, body = post(f'/terminal/session/{sid}/write', {'input': '', 'enter': True})
    print(f"HTTP {sc}: {body[:200]}")

elif cmd == 'output':
    sid = sys.argv[2]
    tail = int(sys.argv[3]) if len(sys.argv) > 3 else 0  # 0 = full
    sc, body = get(f'/terminal/session/{sid}/output')
    if sc != 200:
        print(f"HTTP {sc}: {body[:200]}"); sys.exit(1)
    out = json.loads(body).get('output', '')
    if tail:
        out = '\n'.join(out.splitlines()[-tail:])
    print(out)

else:
    print(__doc__)
    sys.exit(2)
