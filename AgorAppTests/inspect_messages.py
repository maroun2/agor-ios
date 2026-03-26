#!/usr/bin/env python3
"""
Inspect message content shapes from the Agor daemon.
Usage: python3 inspect_messages.py [daemon_url]
"""

import json
import sys
import urllib.request

DAEMON_URL = sys.argv[1] if len(sys.argv) > 1 else "http://107.172.1.123:3030"
EMAIL = "claude-testing@non-existing.com"
PASSWORD = "2TVmd26ARfMFGV9"


def request(path, token=None):
    req = urllib.request.Request(DAEMON_URL + path)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def post(path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(DAEMON_URL + path, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def main():
    auth = post("/authentication", {"strategy": "local", "email": EMAIL, "password": PASSWORD})
    token = auth["accessToken"]

    sessions = request("/sessions?$limit=1&$sort[created_at]=1", token)
    sid = sessions["data"][0]["session_id"]
    print(f"Session: {sid}\n")

    msgs = request(f"/messages?session_id={sid}&$sort[index]=1&$limit=20", token)
    print(f"Total messages: {msgs['total']}\n")

    for m in msgs["data"]:
        role = m.get("role")
        mtype = m.get("type")
        c = m.get("content")

        if isinstance(c, list):
            for block in c:
                btype = block.get("type")
                # Print ALL keys and their values for this block
                print(f"[{mtype}/{role}] block type={btype!r}")
                for k, v in block.items():
                    val = str(v)
                    print(f"  {k}: {val[:120]!r}")
                print()
        else:
            print(f"[{mtype}/{role}] content={str(c)[:120]!r}\n")


if __name__ == "__main__":
    main()
