#!/usr/bin/env python3
"""
tests/helpers/fixture_server.py
A lightweight HTTP server that serves fixture responses for bats tests.

Usage:
    python3 fixture_server.py <port> <map_file>

Map file format (JSON):
    [
      {
        "method": "GET",          (optional, default matches any)
        "pattern": "/wiki/api/v2/pages/12345",   (substring or exact match)
        "fixture": "page_single.json",            (relative to fixtures dir)
        "status": 200                             (optional, default 200)
        "headers": {"X-Custom": "value"}         (optional extra response headers)
      },
      ...
    ]

Environment:
    FIXTURES_DIR   path to fixtures directory (default: ../fixtures relative to this file)
"""

import http.server
import json
import os
import sys
import re
from pathlib import Path

FIXTURES_DIR = Path(os.environ.get(
    "FIXTURES_DIR",
    Path(__file__).parent.parent / "fixtures"
))


def load_map(map_file: str):
    with open(map_file) as f:
        return json.load(f)


def find_route(routes, method, path):
    """Return the first matching route or None."""
    for route in routes:
        route_method = route.get("method", "ANY").upper()
        if route_method != "ANY" and route_method != method.upper():
            continue
        pattern = route.get("pattern", "")
        if route.get("regex"):
            if re.search(pattern, path):
                return route
        else:
            if pattern in path:
                return route
    return None


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    routes = []

    def log_message(self, fmt, *args):
        # Suppress default access log; write to stderr for debugging
        if os.environ.get("FIXTURE_SERVER_VERBOSE"):
            sys.stderr.write(f"[fixture_server] {fmt % args}\n")

    def send_fixture(self, route):
        status = route.get("status", 200)
        fixture_file = route.get("fixture", "")
        extra_headers = route.get("headers", {})

        body = b""
        content_type = "application/json"

        if fixture_file:
            fixture_path = FIXTURES_DIR / fixture_file
            if fixture_path.exists():
                body = fixture_path.read_bytes()
                if fixture_file.endswith(".html"):
                    content_type = "text/html"
            else:
                sys.stderr.write(f"[fixture_server] WARNING: fixture not found: {fixture_path}\n")
                status = 500
                body = json.dumps({"error": f"fixture not found: {fixture_file}"}).encode()

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for k, v in extra_headers.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def handle_request(self):
        route = find_route(self.routes, self.command, self.path)
        if route:
            self.send_fixture(route)
        else:
            sys.stderr.write(f"[fixture_server] No route for {self.command} {self.path}\n")
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            body = json.dumps({"error": "no fixture mapped", "path": self.path}).encode()
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    do_GET = handle_request
    do_POST = handle_request
    do_PUT = handle_request
    do_DELETE = handle_request


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <port> <map_file>", file=sys.stderr)
        sys.exit(1)

    port = int(sys.argv[1])
    map_file = sys.argv[2]

    FixtureHandler.routes = load_map(map_file)

    server = http.server.HTTPServer(("127.0.0.1", port), FixtureHandler)
    sys.stderr.write(f"[fixture_server] Listening on port {port}, map: {map_file}\n")

    # Write PID to stdout so the caller can capture it
    print(os.getpid(), flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
