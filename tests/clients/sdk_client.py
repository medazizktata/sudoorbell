"""The sudo-dialog MCP server driven by the official MCP Python SDK client, as
a reference implementation of the protocol (not Claude Code). sudo is a stub;
no real password is used.

    python sdk_client.py        (with the `mcp` package installed)
"""

import asyncio
import os
import sys
import threading
import urllib.parse
import urllib.request

from mcp import ClientSession, StdioServerParameters, types
from mcp.client.stdio import stdio_client

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
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


def browser(url, password, pages):
    """The user's browser: open the page, then allow with a password."""
    pages.append(urllib.request.urlopen(url, timeout=10).read().decode())
    data = urllib.parse.urlencode({"action": "allow", "password": password}).encode()
    pages.append(urllib.request.urlopen(url, data=data, timeout=20).read().decode())


async def call(mode, answers, log):
    """One sudo tool call. `answers` are the passwords the user gives, in order."""
    seen, pages, notes = [], [], []
    answers = list(answers)

    async def on_elicit(context, params):
        seen.append(params)
        password = answers.pop(0)
        if isinstance(params, types.ElicitRequestURLParams):
            threading.Thread(target=browser, args=(params.url, password, pages), daemon=True).start()
            return types.ElicitResult(action="accept")
        return types.ElicitResult(action="accept", content={"password": password})

    async def on_message(message):
        notes.append(message)

    env = dict(os.environ, SUDO_DIALOG_MCP_MODE=mode, SUDO_DIALOG_MCP_SUDO=stub, SD_STUB_LOG=log)
    params = StdioServerParameters(command=server, env=env)
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write, elicitation_callback=on_elicit, message_handler=on_message) as session:
            init = await session.initialize()
            tools = await session.list_tools()
            result = await session.call_tool("sudo", {"command": ["sh", "-c", "echo hello from root"], "reason": "SDK client test"})
    return init, tools, result, seen, pages


async def main():
    log = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"sd-sdk-{os.getpid()}.log")
    open(log, "w").close()

    init, tools, result, seen, _ = await call("form", ["correct-horse"], log)
    text = result.content[0].text
    check("SDK: handshake", init.server_info.name == "sudo-dialog", init.server_info)
    check("SDK: the sudo tool is listed", [t.name for t in tools.tools] == ["sudo"])
    check("SDK form: one form, with a password field", len(seen) == 1 and "password" in seen[0].requested_schema["properties"])
    check("SDK form: the command ran", "hello from root" in text and not result.is_error, text)

    _, _, result, seen, _ = await call("form", ["wrong-guess", "correct-horse"], log)
    check("SDK form: wrong then right", len(seen) == 2 and "Attempt 2 of 3" in seen[1].message and "hello from root" in result.content[0].text)

    _, _, result, seen, pages = await call("browser", ["correct-horse"], log)
    check("SDK browser: a URL request for a 127.0.0.1 page", len(seen) == 1 and isinstance(seen[0], types.ElicitRequestURLParams) and seen[0].url.startswith("http://127.0.0.1:"))
    check("SDK browser: the page has a hidden field", pages and "type=password" in pages[0])
    check("SDK browser: the command ran", "hello from root" in result.content[0].text and not result.is_error, result.content[0].text)

    with open(log) as f:
        check("SDK: password reached sudo each time", f.read().count("password: ok") == 3)

    print(f"sdk_client.py: {passes} passed, {fails} failed")
    sys.exit(1 if fails else 0)


asyncio.run(main())
