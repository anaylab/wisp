# Usage: python3 scripts/readme-art/render.py hero day numbers team features privacy get faq closing
# Renders each README banner from art.html in headless Chrome at 1600px wide, cut to the card,
# with a transparent page so the rounded corners show either GitHub theme behind them.
import base64, json, subprocess, sys, tempfile, time, urllib.request, os
import websocket  # pip install websocket-client; also needs Google Chrome
ART = os.path.dirname(os.path.abspath(__file__)) + "/art.html"
OUT = os.path.expanduser("~/Downloads/clicky/docs/assets/readme")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
chrome = subprocess.Popen([CHROME, "--headless=new", "--remote-debugging-port=9344", f"--user-data-dir={tempfile.mkdtemp()}",
                           "--allow-file-access-from-files", "--hide-scrollbars", "about:blank"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(50):
        try:
            page = next(t for t in json.load(urllib.request.urlopen("http://127.0.0.1:9344/json")) if t["type"] == "page"); break
        except Exception: time.sleep(0.2)
    ws = websocket.create_connection(page["webSocketDebuggerUrl"], max_size=None)
    n = [0]
    def call(method, **params):
        n[0] += 1; ws.send(json.dumps({"id": n[0], "method": method, "params": params}))
        while True:
            m = json.loads(ws.recv())
            if m.get("id") == n[0]: return m.get("result", {})
    call("Page.enable")
    call("Emulation.setDeviceMetricsOverride", width=1600, height=1400, deviceScaleFactor=1, mobile=False)
    call("Emulation.setDefaultBackgroundColorOverride", color={"r": 0, "g": 0, "b": 0, "a": 0})
    for name in sys.argv[1:]:
        for theme in ("light", "dark"):
            call("Page.navigate", url=f"file://{ART}?name={name}&theme={theme}")
            for _ in range(60):
                time.sleep(0.25)
                title = call("Runtime.evaluate", expression="document.title", returnByValue=True)["result"].get("value")
                if title and title.replace(".", "").isdigit(): break
            time.sleep(0.4)
            height = float(title)
            shot = call("Page.captureScreenshot", format="png",
                        clip={"x": 0, "y": 0, "width": 1600, "height": height, "scale": 1})
            path = f"{OUT}/{name}-{theme}.png"
            open(path, "wb").write(base64.b64decode(shot["data"]))
            print(path.split("/")[-1], int(height), os.path.getsize(path) // 1024, "KB")
finally:
    chrome.terminate()
