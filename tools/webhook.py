#!/usr/bin/env python3
"""A webhook for the event notification checks (ADR-0048): tools/s3_smoke.sh starts it.

usage: webhook.py PORT FILE

Answers 200 to every POST and appends its body, one line each, to FILE.
"""
import http.server
import json
import sys


class Hook(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(sys.argv[2], "a") as out:
            out.write(json.dumps(json.loads(body), separators=(",", ":")) + "\n")
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Hook).serve_forever()
