#!/usr/bin/env python3
"""A signed GET of a node's peer endpoint, as `sender` (0, the operator, as nodes' own asks are signed): prints the
HTTP status, then the body's first line. Standard library only.

usage: peer_get.py <cluster.conf> <cluster.key> <peer port> <path> [sender]
"""
import base64
import hashlib
import hmac
import http.client
import os
import sys
import time


def main():
    conf, key, port, path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    sender = int(sys.argv[5]) if len(sys.argv) > 5 else 0
    with open(conf, "rb") as f:
        digest = hashlib.sha256(f.read()).digest()
    with open(key) as f:
        secret = base64.b64decode(f.read().strip())
    t = int(time.time() * 1000)
    nonce = os.urandom(16).hex()
    text = "\n".join(["cosmo-peer-v1", "GET", path, digest.hex(), str(sender), str(t), nonce,
                      hashlib.sha256(b"").hexdigest()]) + "\n"
    sig = hmac.new(secret, text.encode(), hashlib.sha256).hexdigest()
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    try:
        c.request("GET", path, headers={
            "x-cosmo-cluster": digest.hex(), "x-cosmo-node": str(sender), "x-cosmo-time": str(t),
            "x-cosmo-nonce": nonce, "x-cosmo-signature": sig})
        r = c.getresponse()
        body = r.read()
        print(r.status, body.split(b"\n", 1)[0].decode(errors="replace"))
    finally:
        c.close()


if __name__ == "__main__":
    main()
