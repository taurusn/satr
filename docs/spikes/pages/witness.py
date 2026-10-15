"""Witness for spike P(a): logs the request line of every connection to 127.0.0.1:<port>, any method.

Usage: python3 -I witness.py <port> <log>
"""
import http.server, sys

PORT, LOG = int(sys.argv[1]), sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def _any(self):
        with open(LOG, "a") as f:
            f.write(f"{self.command} {self.path}\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(b"x")

    def setup(self):
        super().setup()
        with open(LOG, "a") as f:
            f.write(f"TCP {__import__('time').time():.2f}\n")

    do_GET = do_POST = do_HEAD = do_OPTIONS = do_PUT = _any

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
