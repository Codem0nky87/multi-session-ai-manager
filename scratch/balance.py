import json, socket, os, glob

socks = glob.glob("/Users/rufus/.config/herdr/sessions/woodhouse/*.sock")
socket_path = socks[0]

def send_req(req):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
        c.connect(socket_path)
        c.sendall((json.dumps(req) + "\n").encode())
        d = b""
        while b"\n" not in d:
            d += c.recv(4096)
        return json.loads(d.decode().strip())

# First get layout
res = send_req({"id": "get", "method": "pane.layout", "params": {}})
layout = res["result"]["layout"]
splits = layout.get("splits", [])

# Find root split
for s in splits:
    if s["id"] == "split_0_root":
        print(send_req({
            "id": "resize1",
            "method": "pane.resize",
            "params": {
                "pane_id": layout["panes"][0]["pane_id"],
                "split_id": "split_0_root",
                "ratio": 0.66666
            }
        }))
    elif s["id"] == "split_1_0":
        print(send_req({
            "id": "resize2",
            "method": "pane.resize",
            "params": {
                "pane_id": layout["panes"][0]["pane_id"],
                "split_id": "split_1_0",
                "ratio": 0.5
            }
        }))
