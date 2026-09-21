#!/usr/bin/env python3
"""A Range origin that answers the way a HOST PROXY does, for PRISMCORE_BENCH.

Aether does not hand the engine a server URL: SMB, WebDAV and Wellspring
sources go through a localhost range proxy, and that proxy fetches each
forwarded window WHOLE before it writes a byte. FFmpeg's HTTP asks for
`bytes=N-`, so an open and every backward seek wait for a full bite of the
proxy's chunk size, however few bytes the demuxer actually wanted. A normal
Range server answers immediately and hides the entire cost — which is how a
startup that takes 18 s on a device benchmarks at 60 ms here.

    CHUNK_BYTES=8388608 RATE_BPS=800000 python3 Scripts/proxy-model-server.py movie.mkv 8732
    PRISMCORE_BENCH=http://127.0.0.1:8732/movie.mkv swift test --filter checkpointLine

CHUNK_BYTES is the proxy's forwarded window (8 MB is Aether's), RATE_BPS the
origin's throughput behind it, RTT_MS one round trip, REQLOG a file to record
each request in — the count is the number that matters.
"""

import os, re, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Models AetherCore's WellspringRangeProxy: every forwarded GET is fetched from
# the origin with URLSession.data(for:) in <= CHUNK byte bites, so the first
# byte reaches the player only after the whole first bite has been downloaded.
PATH  = sys.argv[1]
PORT  = int(sys.argv[2])
CHUNK = int(os.environ.get("CHUNK_BYTES", 8 * 1024 * 1024))
RATE  = float(os.environ.get("RATE_BPS", 800_000))   # origin bytes/second
RTT   = float(os.environ.get("RTT_MS", "40")) / 1000.0
LOG   = os.environ.get("REQLOG", "/dev/null")
SIZE  = os.path.getsize(PATH)
lock  = threading.Lock()

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def _note(self, line):
        with lock:
            with open(LOG, "a") as f: f.write(line + "\n")

    def do_HEAD(self): self._serve(True)
    def do_GET(self):  self._serve(False)

    def _serve(self, head):
        rng = self.headers.get("Range")
        start, end, partial = 0, SIZE - 1, False
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)", rng)
            if m:
                partial = True
                if m.group(1):
                    start = int(m.group(1))
                    if m.group(2): end = min(int(m.group(2)), SIZE - 1)
                else:
                    start = max(0, SIZE - int(m.group(2)))
        if start >= SIZE:
            self.send_response(416); self.send_header("Content-Range", "bytes */%d" % SIZE)
            self.send_header("Content-Length", "0"); self.end_headers(); return
        length = end - start + 1
        if head:
            time.sleep(RTT)
            self.send_response(200); self.send_header("Content-Length", str(SIZE))
            self.send_header("Accept-Ranges", "bytes"); self.end_headers(); return
        # The proxy's first bite: downloaded in full before anything is written out.
        bite = min(length, CHUNK)
        time.sleep(RTT + bite / RATE)
        self._note("%.3f GET %s -> %d-%d (window %d, first bite %d, held %.2fs)"
                   % (time.time(), rng or "-", start, end, length, bite, RTT + bite / RATE))
        self.send_response(206 if partial else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(length))
        if partial:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, SIZE))
        self.end_headers()
        try:
            with open(PATH, "rb") as f:
                f.seek(start)
                remaining = length
                sent_in_bite = 0
                while remaining > 0:
                    n = min(262144, remaining)
                    data = f.read(n)
                    if not data: break
                    self.wfile.write(data)
                    remaining -= len(data); sent_in_bite += len(data)
                    if sent_in_bite >= bite and remaining > 0:
                        bite = min(remaining, CHUNK)
                        sent_in_bite = 0
                        time.sleep(RTT + bite / RATE)   # next bite, same buffering
        except (BrokenPipeError, ConnectionResetError):
            pass

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
