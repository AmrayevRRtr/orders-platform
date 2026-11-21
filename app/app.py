"""Tiny web service for the ECS Fargate part of SIS 3 (standard library only)."""
import os
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer

ENV = os.environ.get("APP_ENV", "dev")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self._send(200, "ok")
        else:
            self._send(200, "Hello from ECS Fargate! env=%s container=%s" % (ENV, socket.gethostname()))

    def _send(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # one line per request to stdout -> CloudWatch
        print("%s %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
