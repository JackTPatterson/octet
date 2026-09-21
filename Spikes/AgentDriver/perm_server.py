#!/usr/bin/env python3
"""Spike: the permission tool Claude calls for each prompt
(--permission-prompt-tool mcp__octetperm__approve). Minimal stdio MCP server.
Allows by default; denies any Bash command containing "deny". Every request is
appended to $PERM_LOG as JSON, so the harness can see the round trip."""
import json, os, sys, time

LOG = os.environ.get("PERM_LOG", "/tmp/octetperm.log")

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    try:
        req = json.loads(line)
    except ValueError:
        continue
    method, rid = req.get("method"), req.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": req.get("params", {}).get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "octetperm", "version": "0.1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": rid, "result": {"tools": [{
            "name": "approve",
            "description": "Answers Claude Code permission prompts for the Octet spike.",
            "inputSchema": {"type": "object", "properties": {
                "tool_name": {"type": "string"}, "input": {"type": "object"},
                "tool_use_id": {"type": "string"}}, "required": ["tool_name", "input"]}}]}})
    elif method == "tools/call":
        args = req.get("params", {}).get("arguments", {})
        command = json.dumps(args.get("input", {}))
        if "deny" in command:
            decision = {"behavior": "deny", "message": "Denied by the Octet spike."}
        else:
            decision = {"behavior": "allow", "updatedInput": args.get("input", {})}
        with open(LOG, "a") as f:
            f.write(json.dumps({"at": time.time(), "args": args, "decision": decision}) + "\n")
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "content": [{"type": "text", "text": json.dumps(decision)}]}})
    elif rid is not None:
        send({"jsonrpc": "2.0", "id": rid, "result": {}})
