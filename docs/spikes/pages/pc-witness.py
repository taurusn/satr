"""Witness for spike P(c): logs every way out of a sealed page, on loopback and on the Mac's Wi-Fi address.

- HTTP (and WebSocket upgrades, which arrive as GET lines) on 127.0.0.1, [::1] and <lan_ip>, port <http_port>.
- UDP and TCP on all three addresses, ports <base>..<base>+239: STUN, TURN and QUIC packets from WebRTC and
  WebTransport. Each (seal, realm) pair aims at its own port, so the port names the probe.
- mDNS (224.0.0.251:5353): any query whose name contains "linenprobe".

Usage: python3 -I pc-witness.py <http_port> <lan_ip> <base> <log>
"""
import http.server, resource, selectors, socket, struct, sys, threading, time

HTTP_PORT, LAN, BASE, LOG = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]
resource.setrlimit(resource.RLIMIT_NOFILE, (4096, 4096))
lock = threading.Lock()


def log(line):
    with lock, open(LOG, "a") as f:
        f.write(f"{time.time():.2f} {line}\n")


class Handler(http.server.BaseHTTPRequestHandler):
    def _any(self):
        log(f"HTTP {self.server.server_address[0]} {self.command} {self.path}")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(b"x")

    do_GET = do_POST = do_HEAD = do_OPTIONS = do_PUT = _any

    def log_message(self, *a):
        pass


def sockets():
    sel = selectors.DefaultSelector()
    for addr in ("127.0.0.1", LAN, "::1"):
        fam = socket.AF_INET6 if ":" in addr else socket.AF_INET
        for port in range(BASE, BASE + 240):
            u = socket.socket(fam, socket.SOCK_DGRAM)
            u.bind((addr, port))
            u.setblocking(False)
            sel.register(u, selectors.EVENT_READ, ("UDP", addr, port))
            t = socket.socket(fam, socket.SOCK_STREAM)
            t.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            t.bind((addr, port))
            t.listen(16)
            t.setblocking(False)
            sel.register(t, selectors.EVENT_READ, ("TCP", addr, port))
    while True:
        for key, _ in sel.select():
            kind, addr, port = key.data
            try:
                if kind == "UDP":
                    data, src = key.fileobj.recvfrom(4096)
                    log(f"UDP {addr} port={port} off={port - BASE} bytes={len(data)}")
                else:
                    c, src = key.fileobj.accept()
                    log(f"TCP {addr} port={port} off={port - BASE}")
                    c.close()
            except OSError:
                pass


def labels(data):
    out, cur = [], bytearray()
    for b in data:
        if 45 <= b <= 122:
            cur.append(b)
        else:
            if len(cur) > 3:
                out.append(cur.decode("ascii", "replace"))
            cur = bytearray()
    if len(cur) > 3:
        out.append(cur.decode("ascii", "replace"))
    return [x for x in out if "linenprobe" in x]


def mdns():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.bind(("", 5353))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, struct.pack("4s4s", socket.inet_aton("224.0.0.251"), socket.inet_aton("0.0.0.0")))
    while True:
        data, src = s.recvfrom(9000)
        for name in labels(data):
            log(f"MDNS {name}")


threading.Thread(target=sockets, daemon=True).start()
threading.Thread(target=mdns, daemon=True).start()
lan_http = http.server.ThreadingHTTPServer((LAN, HTTP_PORT), Handler)
threading.Thread(target=lan_http.serve_forever, daemon=True).start()


class V6(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


v6_http = V6(("::1", HTTP_PORT), Handler)
threading.Thread(target=v6_http.serve_forever, daemon=True).start()
log("ready")
http.server.ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), Handler).serve_forever()
