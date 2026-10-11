"""The Claude Code MCP server, driven the way Claude Code drives it: a client
that answers the password form. sudo is a stub; no real password is used."""

import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
server = os.path.join(root, "mcp", "sudo-dialog-mcp")
stub = os.path.join(root, "tests", "stubs", "sudo-password-stub")
passes = fails = 0


def check(name, ok, detail=""):
    global passes, fails
    if ok:
        passes += 1
        print(f"ok    {name}")
    else:
        fails += 1
        print(f"FAIL  {name}")
        if detail:
            print(f"      {detail}")


def browse(url, actions, pages, host=None):
    """Act as the user's browser: open the page, then submit each (action,
    password) in turn. Records every page seen in `pages`."""
    port = urllib.parse.urlsplit(url).port

    def fetch(data=None):
        req = urllib.request.Request(url, data=data, headers={"Host": host or f"127.0.0.1:{port}"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    pages.append(fetch())
    for action, password in actions:
        pages.append(fetch(urllib.parse.urlencode({"action": action, "password": password}).encode()))


def session(answers, arguments, capabilities=None, mode="form", browser=(), browser_host=None):
    """Run one tool call. `answers` are the form responses, in order; in
    browser mode `browser` is what the user does on the page. Returns
    (tool result, forms shown, stub log, everything the server wrote, tools)."""
    global last_pages, last_notes
    last_pages, last_notes = [], []
    log = tempfile.NamedTemporaryFile(delete=False).name
    env = dict(os.environ, SUDO_DIALOG_MCP_SUDO=stub, SD_STUB_LOG=log, SUDO_DIALOG_MCP_MODE=mode, SUDO_DIALOG_MCP_WAIT="5")
    p = subprocess.Popen([server], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)
    wire = []

    def send(m):
        p.stdin.write(json.dumps(m) + "\n")
        p.stdin.flush()

    def recv():
        line = p.stdout.readline()
        wire.append(line)
        return json.loads(line)

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18",
        "capabilities": {"elicitation": {}} if capabilities is None else capabilities,
        "clientInfo": {"name": "test", "version": "0"}}})
    recv()
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    tools = recv()["result"]["tools"]
    send({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "sudo", "arguments": arguments}})
    forms = []
    answers = list(answers)
    user = None
    while True:
        m = recv()
        if m.get("method") == "elicitation/create":
            forms.append(m["params"])
            answer = answers.pop(0)
            send({"jsonrpc": "2.0", "id": m["id"], "result": answer})
            if m["params"].get("mode") == "url" and answer.get("action") == "accept" and browser:
                user = threading.Thread(target=browse, args=(m["params"]["url"], browser, last_pages, browser_host))
                user.start()
        elif m.get("method"):
            last_notes.append(m)
        elif m.get("id") == 3:
            result = m["result"]
            break
    if user:
        user.join(timeout=20)
    p.stdin.close()
    p.wait(timeout=10)
    with open(log) as f:
        stub_log = f.read()
    return result, forms, stub_log, "".join(wire), tools


def text(result):
    return result["content"][0]["text"]


allow = {"action": "accept", "content": {"password": "correct-horse"}}
wrong = {"action": "accept", "content": {"password": "wrong-guess"}}
deny = {"action": "decline"}
args = {"command": ["sh", "-c", "echo hello from root; echo to-stderr >&2"], "reason": "test"}

result, forms, stub_log, wire, tools = session([allow], args)
check("lists one tool named sudo", [t["name"] for t in tools] == ["sudo"])
check("one form shown", len(forms) == 1)
check("form names the command", "sudo sh -c 'echo hello from root; echo to-stderr >&2'" in forms[0]["message"], forms[0]["message"])
check("form gives the reason", "Reason: test" in forms[0]["message"])
check("form asks for a password field", list(forms[0]["requestedSchema"]["properties"]) == ["password"])
check("allow: command ran", "hello from root" in text(result) and not result["isError"], text(result))
check("allow: stderr reported", "to-stderr" in text(result))
check("allow: password reached sudo", "password: ok" in stub_log)
check("sudo asked for a fresh password (-k) on stdin (-S)", "arg: -S" in stub_log and "arg: -k" in stub_log)
check("password never sent back to the client", "correct-horse" not in wire)

result, forms, stub_log, wire, _ = session([wrong, allow], args)
check("wrong then right: asked twice", len(forms) == 2)
check("wrong then right: second form says so", "Wrong password. Attempt 2 of 3." in forms[1]["message"])
check("wrong then right: command ran", "hello from root" in text(result))
check("wrong password never sent back", "wrong-guess" not in wire)

result, forms, stub_log, _, _ = session([wrong, wrong, wrong], args)
check("three wrong: gives up", len(forms) == 3 and "Wrong password 3 times" in text(result) and result["isError"])
check("three wrong: command never ran", "password: ok" not in stub_log)

result, forms, stub_log, _, _ = session([deny], args)
check("decline: not run", result["isError"] and "declined" in text(result) and stub_log == "")

result, forms, stub_log, _, _ = session([{"action": "cancel"}], args)
check("cancel: not run", result["isError"] and stub_log == "")

result, forms, _, _, _ = session([], args, capabilities={})
check("client without forms: refused, no form", result["isError"] and forms == [] and "cannot ask the user for a password" in text(result))

result, forms, _, _, _ = session([], {"command": "echo hi; id", "reason": "x"})
check("a shell string is refused", result["isError"] and forms == [])

result, _, _, _, _ = session([allow], {"command": ["sh", "-c", "exit 3"], "reason": "x"})
check("command failure: exit code reported", "exit code: 3" in text(result) and result["isError"])

# Browser mode: a local page with a hidden field.
both = {"elicitation": {"form": {}, "url": {}}}
go = {"action": "accept"}
result, forms, stub_log, wire, _ = session([go], args, both, "browser", [("allow", "correct-horse")])
check("browser: asks Claude Code to open a page", forms and forms[0]["mode"] == "url" and forms[0]["url"].startswith("http://127.0.0.1:"))
check("browser: the page shows the command", last_pages and "sudo sh -c" in last_pages[0][1] and "Run as root" in last_pages[0][1])
check("browser: the password field is hidden", 'type=password' in last_pages[0][1])
check("browser: allow runs the command", "hello from root" in text(result) and "password: ok" in stub_log, text(result))
check("browser: the page says it is done", "Allowed" in last_pages[-1][1])
check("browser: password never sent to Claude Code", "correct-horse" not in wire)
check("browser: Claude Code told the page is complete", any(n.get("method") == "notifications/elicitation/complete" for n in last_notes))

result, forms, stub_log, _, _ = session([go], args, both, "browser", [("allow", "wrong-guess"), ("allow", "correct-horse")])
check("browser: wrong then right", "hello from root" in text(result) and "Attempt 2 of 3" in last_pages[1][1], [p[1][-200:] for p in last_pages])

result, forms, stub_log, _, _ = session([go], args, both, "browser", [("deny", "")])
check("browser: deny runs nothing", result["isError"] and "declined" in text(result) and stub_log == "")

result, forms, stub_log, _, _ = session([{"action": "decline"}], args, both, "browser")
check("browser: declining to open the page runs nothing", result["isError"] and stub_log == "")

result, forms, stub_log, _, _ = session([go], args, both, "browser", [("allow", "correct-horse")], browser_host="evil.example:80")
check("browser: a request with a foreign Host is refused", last_pages[0][0] == 403 and stub_log == "", last_pages[0][0])

result, forms, _, _, _ = session([go], args, both, "browser")
check("browser: nobody answers, gives up", result["isError"] and "Nobody answered" in text(result))

result, forms, _, _, _ = session([], args, {"elicitation": {}}, "browser")
check("browser: a client without URL support is refused, not given the visible form", result["isError"] and forms == [] and "browser mode needs it" in text(result))

print(f"test_mcp.py: {passes} passed, {fails} failed")
sys.exit(1 if fails else 0)
