#!/usr/bin/env python3
"""Spike, driver A: Octet drives `claude -p` directly over stream-json using
only documented flags. One long-lived process for several turns, permission
prompts through an MCP tool, interrupt by SIGINT, then --resume.

Prints a timing and behavior report. Run from a scratch folder: sessions it
creates belong to the current directory's project."""
import json, os, signal, subprocess, sys, threading, time, uuid, queue

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.environ.get("SPIKE_WORKDIR", os.getcwd())
PERM_LOG = os.path.join(WORK, "perm.log")
MODEL = os.environ.get("SPIKE_MODEL", "haiku")
SESSION = str(uuid.uuid4())

mcp_config = json.dumps({"mcpServers": {"octetperm": {
    "type": "stdio", "command": sys.executable, "args": [os.path.join(HERE, "perm_server.py")],
    "env": {"PERM_LOG": PERM_LOG}}}})

def launch(resume=False):
    args = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--model", MODEL, "--tools", "Bash",
            "--mcp-config", mcp_config, "--permission-prompt-tool", "mcp__octetperm__approve"]
    args += ["--resume", SESSION] if resume else ["--session-id", SESSION]
    started = time.monotonic()
    proc = subprocess.Popen(args, cwd=WORK, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, bufsize=1)
    events = queue.Queue()
    def pump():
        for line in proc.stdout:
            try:
                events.put((time.monotonic(), json.loads(line)))
            except ValueError:
                events.put((time.monotonic(), {"type": "raw", "line": line}))
        events.put((time.monotonic(), {"type": "eof"}))
    threading.Thread(target=pump, daemon=True).start()
    return proc, events, started

def send(proc, text):
    proc.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": text},
                                 "parent_tool_use_id": None}) + "\n")
    proc.stdin.flush()
    return time.monotonic()

def turn(proc, events, text, label, interrupt_after_first_token=False, timeout=120):
    """Sends one message; waits for its result. Returns a dict of findings."""
    sent = send(proc, text)
    first_token = None
    reply, tools, denials = [], [], []
    while True:
        try:
            at, ev = events.get(timeout=timeout)
        except queue.Empty:
            return {"label": label, "error": "timeout"}
        kind = ev.get("type")
        if ev.get("subtype") == "init":
            report.setdefault("init_after_first_send_s", round(at - sent, 2))
            report["mcp"] = [(m["name"], m["status"]) for m in ev.get("mcp_servers", []) if m["name"] == "octetperm"]
        if kind == "stream_event" and ev["event"].get("type") == "content_block_delta":
            delta = ev["event"].get("delta", {})
            if first_token is None and delta.get("type") == "text_delta":
                first_token = at - sent
                if interrupt_after_first_token:
                    proc.send_signal(signal.SIGINT)
            reply.append(delta.get("text", ""))
        elif kind == "assistant":
            for block in ev["message"].get("content", []):
                if block.get("type") == "tool_use":
                    tools.append(block.get("name"))
        elif kind == "result":
            denials = ev.get("permission_denials", [])
            return {"label": label, "ttft_s": round(first_token, 2) if first_token else None,
                    "total_s": round(at - sent, 2), "reply": "".join(reply).strip()[:160],
                    "tools": tools, "denials": len(denials), "subtype": ev.get("subtype"),
                    "cost_usd": ev.get("total_cost_usd")}
        elif kind == "eof":
            return {"label": label, "ttft_s": round(first_token, 2) if first_token else None,
                    "process_exited": proc.wait(), "reply": "".join(reply).strip()[:160], "tools": tools}

report = {"session": SESSION, "model": MODEL, "turns": []}
proc, events, started = launch()
# In stream-json input mode the init message only arrives after the first
# user message, so turn 1 carries the cold start; turn() records it.
ONLY_PERM = os.environ.get("SPIKE_ONLY") == "perm"
report["turns"].append(turn(proc, events, "Reply with just the word: one", "1 first turn"))
if not ONLY_PERM:
    report["turns"].append(turn(proc, events, "Reply with just the word: two", "2 warm turn"))
report["turns"].append(turn(proc, events, "Use the Bash tool to run exactly: touch spike-allowed.txt  then reply with just: done", "3 permission allow"))
report["turns"].append(turn(proc, events, "Use the Bash tool to run exactly: touch please-deny.txt  then say what happened in one short sentence.", "4 permission deny"))
if not ONLY_PERM:
    report["turns"].append(turn(proc, events, "Count from 1 to 300, one number per line, nothing else.", "5 interrupt", interrupt_after_first_token=True))
    report["after_interrupt_exit"] = proc.poll()
    if proc.poll() is None:
        proc.stdin.close(); proc.wait(timeout=30)

    proc, events, started = launch(resume=True)
    report["turns"].append(turn(proc, events, "What single word did my very first message ask you to reply with? Reply with just that word.", "6 resume after interrupt"))
else:
    proc.stdin.close(); proc.wait(timeout=30)
if proc.poll() is None:
    proc.stdin.close(); proc.wait(timeout=30)

report["permission_requests"] = [json.loads(l) for l in open(PERM_LOG)] if os.path.exists(PERM_LOG) else []
print(json.dumps(report, indent=2))
