#!/usr/bin/env python3
"""Talk to one MCP connector over stdio, with no AI involved: handshake, list its tools, optionally call one.

Usage: mcp_probe.py [--call TOOL JSON_ARGS] [--grep WORD] -- command arg...
Prints one summary line (tool count), then tool names, then the call result (first 600 characters).
Exit code 0 only when the handshake worked and the call (if any) did not return an error.
"""
import json, os, select, subprocess, sys, time

def main():
    a = sys.argv[1:]
    call = grep = None
    while a and a[0] != "--":
        if a[0] == "--call":
            call = (a[1], json.loads(a[2])); a = a[3:]
        elif a[0] == "--grep":
            grep = a[1].lower(); a = a[2:]
        else:
            sys.exit("unknown option " + a[0])
    cmd = a[1:]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ.copy())
    buf = b""

    def send(obj):
        p.stdin.write((json.dumps(obj) + "\n").encode()); p.stdin.flush()

    def wait(rid, timeout=60):
        nonlocal buf
        end = time.time() + timeout
        while time.time() < end:
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                if m.get("id") == rid:
                    return m
            if p.poll() is not None and not select.select([p.stdout], [], [], 0)[0]:
                break
            if select.select([p.stdout], [], [], 0.5)[0]:
                chunk = os.read(p.stdout.fileno(), 65536)
                if chunk:
                    buf += chunk
        return None

    rc = 1
    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "lite-probe", "version": "1"}}})
        r = wait(1)
        if not r or "result" not in r:
            print("HANDSHAKE FAILED:", json.dumps(r)[:300] if r else "no answer")
            return 1
        info = r["result"].get("serverInfo", {})
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        r = wait(2)
        tools = (r or {}).get("result", {}).get("tools", [])
        print(f"server={info.get('name')} {info.get('version')} tools={len(tools)}")
        names = [t["name"] for t in tools]
        shown = [n for n in names if not grep or grep in n.lower()]
        print("names:", " ".join(shown[:80]))
        for t in tools:
            if os.environ.get("PROBE_SCHEMA") and t["name"] in os.environ["PROBE_SCHEMA"].split(","):
                print("schema", t["name"], json.dumps(t.get("inputSchema", {}))[:1200])
        rc = 0 if tools else 1
        if call and rc == 0:
            send({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": call[0], "arguments": call[1]}})
            r = wait(3, 90)
            if not r:
                print("CALL: no answer"); rc = 1
            elif "error" in r:
                print("CALL ERROR:", json.dumps(r["error"])[:400]); rc = 1
            else:
                res = r["result"]
                text = " ".join(c.get("text", "") for c in res.get("content", []) if isinstance(c, dict))
                print("CALL", "ERROR:" if res.get("isError") else "OK:", " ".join(text.split())[:600])
                rc = 1 if res.get("isError") else 0
    finally:
        try:
            p.stdin.close()
        except Exception:
            pass
        try:
            p.wait(timeout=5)
        except Exception:
            p.kill()
        if rc:
            err = p.stderr.read().decode(errors="replace").strip().splitlines()[-6:]
            if err:
                print("stderr:", " | ".join(x[:200] for x in err))
    return rc

if __name__ == "__main__":
    sys.exit(main())
