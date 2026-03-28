#!/usr/bin/env python3
"""Harvest cookies from a Chrome CDP endpoint and save as JSON."""
import asyncio, json, sys, urllib.request

async def harvest(port, output_path):
    import websockets
    # Get page targets
    resp = urllib.request.urlopen(f"http://127.0.0.1:{port}/json")
    targets = json.loads(resp.read())

    all_cookies = {}

    for target in targets:
        if target.get("type") != "page":
            continue
        ws_url = target.get("webSocketDebuggerUrl")
        if not ws_url:
            continue

        try:
            async with websockets.connect(ws_url) as ws:
                await ws.send(json.dumps({"id": 1, "method": "Network.enable"}))
                await asyncio.wait_for(ws.recv(), timeout=5)

                await ws.send(json.dumps({"id": 2, "method": "Network.getCookies"}))
                r = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))

                for c in r.get("result", {}).get("cookies", []):
                    key = (c["name"], c["domain"], c.get("path", "/"))
                    if key not in all_cookies:
                        all_cookies[key] = {
                            "name": c["name"],
                            "value": c["value"],
                            "domain": c["domain"],
                            "path": c.get("path", "/"),
                            "secure": c.get("secure", False),
                            "http_only": c.get("httpOnly", False),
                        }
                        if "expires" in c and c["expires"] > 0:
                            all_cookies[key]["expires"] = int(c["expires"])
        except Exception as e:
            print(f"  skip {target.get('url','')}: {e}", file=sys.stderr)
            continue

    cookies = list(all_cookies.values())

    with open(output_path, "w") as f:
        json.dump(cookies, f)

    print(len(cookies))

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9444
    output = sys.argv[2] if len(sys.argv) > 2 else ""
    if not output:
        import os
        output = os.path.expanduser("~/.playpanda/cookies.json")
        os.makedirs(os.path.dirname(output), exist_ok=True)

    asyncio.run(harvest(port, output))
