"""Witness for spike P(b): logs every way out that P(a)'s witness could not see.

- HTTP on 127.0.0.1:<http_port> (request lines, as witness.py).
- UDP and TCP on <lan_ip>:<udp_base>+i for i in 0..9: STUN, TURN and QUIC packets from WebRTC and WebTransport.
  Each seal aims at its own port, so the port names the seal.
- mDNS (224.0.0.251:5353): any query whose name contains "linenprobe", which shows a name lookup left the page.

Usage: python3 -I witness2.py <http_port> <lan_ip> <udp_base> <log>
"""
import http.server, socket, struct, sys, threading, time

HTTP_PORT, LAN, UDP_BASE, LOG = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]
lock = threading.Lock()


def log(line):
    with lock, open(LOG, "a") as f:
        f.write(f"{time.time():.2f} {line}\n")


class Handler(http.server.BaseHTTPRequestHandler):
    def _any(self):
        log(f"HTTP {self.command} {self.path}")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(b"x")

    do_GET = do_POST = do_HEAD = do_OPTIONS = do_PUT = _any

    def log_message(self, *a):
        pass


def udp(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((LAN, port))
    while True:
        data, src = s.recvfrom(4096)
        log(f"UDP port={port} seal={port - UDP_BASE} from={src[0]}:{src[1]} bytes={len(data)}")


def tcp(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((LAN, port))
    s.listen(16)
    while True:
        c, src = s.accept()
        log(f"TCP port={port} seal={port - UDP_BASE} from={src[0]}:{src[1]}")
        c.close()


def labels(data):
    # Pull printable runs out of the DNS packet; names are length-prefixed labels.
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
            log(f"MDNS {name} from={src[0]}")


for i in range(10):
    threading.Thread(target=udp, args=(UDP_BASE + i,), daemon=True).start()
    threading.Thread(target=tcp, args=(UDP_BASE + i,), daemon=True).start()
threading.Thread(target=mdns, daemon=True).start()
log("ready")
http.server.ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), Handler).serve_forever()
