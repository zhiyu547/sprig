#!/usr/bin/env python3
# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

"""Local-only UI regression fixture. Does not log prompts, headers or credentials."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        route = self.path.split("/")[1]
        print("mock request:", route, flush=True)
        if route == "slow":
            time.sleep(30)
        if route == "error":
            status, payload = 401, {"error": {"message": "Synthetic authentication failure"}}
        else:
            time.sleep(1)
            status, payload = 200, {"choices": [{"finish_reason": "stop", "message": {"content": "docs: update QA instructions\n\n- 更新 README 的隔离验证说明"}}]}
        data = json.dumps(payload, ensure_ascii=False).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 8769), Handler)
    print("Mock AI listening at http://127.0.0.1:8769/{success,slow,error}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
