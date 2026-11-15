#!/usr/bin/env python3
"""A forwarded write is done once (ADR-0068), checked directly: three nodes; a PUT forwarded to its shard's leader, as a
node forwards it, with a request id; another PUT of the same key; the first sent again with the same id. The second
sending must be answered as the first was (its ETag) and must not be done again: the key keeps the other value. A
fresh id is done. Standard library only; uses cluster_chaos.py's cluster, proxy and SigV4.

usage: cluster_sessions_check.py [--binary out/cosmostore] [--port-base 20900]
"""
import argparse
import base64
import hashlib
import hmac
import http.client
import os
import shutil
import struct
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cluster_chaos as cc  # noqa: E402

passed = failed = 0


def check(name, got, want):
    global passed, failed
    if got == want:
        print(f"ok   {name}")
        passed += 1
    else:
        print(f"FAIL {name}: expected [{want}], got [{got}]")
        failed += 1


def b32(b):
    return struct.pack("<I", len(b)) + b


def encode_raw(method, target, headers, body):
    out = struct.pack("<H", 0) + b32(method) + b32(target) + struct.pack("<I", len(headers))
    for n, v in headers:
        out += b32(n.lower().encode()) + b32(v.encode())
    return out + b32(body)


def decode_raw(b):
    at = 0

    def take32():
        nonlocal at
        (n,) = struct.unpack_from("<I", b, at)
        at += 4
        v = b[at:at + n]
        at += n
        return v
    (status,) = struct.unpack_from("<H", b, 0)
    at = 2
    take32()
    take32()
    (count,) = struct.unpack_from("<I", b, at)
    at += 4
    headers = {}
    for _ in range(count):
        n = take32().decode()
        headers[n] = take32().decode()
    return status, headers, take32()


def peer_post(port, path, body, digest, secret, sender):
    t = int(time.time() * 1000)
    nonce = os.urandom(16).hex()
    text = "\n".join(["cosmo-peer-v1", "POST", path, digest.hex(), str(sender), str(t), nonce,
                      hashlib.sha256(body).hexdigest()]) + "\n"
    sig = hmac.new(secret, text.encode(), hashlib.sha256).hexdigest()
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    try:
        c.request("POST", path, body=body, headers={
            "x-cosmo-cluster": digest.hex(), "x-cosmo-node": str(sender), "x-cosmo-time": str(t),
            "x-cosmo-nonce": nonce, "x-cosmo-signature": sig, "content-type": "application/octet-stream"})
        r = c.getresponse()
        return r.status, r.read()
    finally:
        c.close()


def forwarded_put(cluster, digest, secret, key, value, request_id):
    """The PUT as another node would forward it: signed by the client for node 1's S3 port, with the request id. Sent to
    each node and shard until a leader takes it: (inner status, ETag)."""
    host_port = cluster.s3_port(1)
    path = f"/{cc.BUCKET}/{key}"
    body = value.encode()
    headers = cc.authorize("PUT", f"127.0.0.1:{host_port}", path, "", {}, body)
    pairs = list(headers.items()) + [("x-cosmo-request", request_id.hex())]
    raw = encode_raw(b"PUT", path.encode(), pairs, body)
    for _ in range(150):
        for node in range(1, cluster.n + 1):
            for shard in range(2):
                # Signed as another node: a node refuses a request that says it is from itself.
                sender = 1 if node != 1 else 2
                status, answer = peer_post(cluster.proxy_port(node), "/s3", struct.pack("<I", shard) + raw, digest,
                                           secret, sender)
                if status != 200:
                    continue
                inner, h, _ = decode_raw(answer)
                if inner == 200:
                    return inner, h.get("etag", "")
        time.sleep(0.2)
    return None, ""


def get_value(cluster, key):
    status, data = cc.s3(cluster.s3_port(3), "GET", f"/{cc.BUCKET}/{key}")
    return data.decode() if status == 200 else f"({status})"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--binary", default="out/cosmostore")
    p.add_argument("--port-base", type=int, default=20900)
    args = p.parse_args()
    work = tempfile.mkdtemp(prefix="cosmo-sessions-")
    cluster = cc.Cluster(os.path.abspath(args.binary), work, 3, args.port_base)
    proxy = cc.Proxy({i: (cluster.proxy_port(i), cluster.peer_port(i)) for i in range(1, 4)})
    proxy.start()
    try:
        for i in range(1, 4):
            cluster.start(i)
        # Every shard with a leader before the first request (as the chaos harness waits).
        deadline = time.time() + 30
        while time.time() < deadline:
            rows = cluster.status(1)
            if rows and all(r[3] != "0" for r in rows):
                break
            time.sleep(0.2)
        with open(cluster.conf, "rb") as f:
            digest = hashlib.sha256(f.read()).digest()
        with open(os.path.join(work, "cluster.key")) as f:
            secret = base64.b64decode(f.read().strip())
        for _ in range(50):
            status, _ = cc.s3(cluster.s3_port(1), "PUT", f"/{cc.BUCKET}")
            if status == 200:
                break
            time.sleep(0.2)
        check("the bucket is made", status, 200)
        first_id = os.urandom(16)
        s1, etag1 = forwarded_put(cluster, digest, secret, "k", "first", first_id)
        check("a forwarded PUT with an id is done", s1, 200)
        check("its value is there", get_value(cluster, "k"), "first")
        s2, _ = cc.s3(cluster.s3_port(2), "PUT", f"/{cc.BUCKET}/k", body=b"other")
        check("another PUT of the key", s2, 200)
        s3, etag3 = forwarded_put(cluster, digest, secret, "k", "first", first_id)
        check("the first sent again is answered", s3, 200)
        check("as it was the first time (its ETag)", etag3, etag1)
        check("and not done again: the key keeps the other value", get_value(cluster, "k"), "other")
        s4, _ = forwarded_put(cluster, digest, secret, "k", "fresh", os.urandom(16))
        check("a fresh id is done", (s4, get_value(cluster, "k")), (200, "fresh"))
    finally:
        proxy.stop()
        cluster.stop_all()
        if failed == 0:
            shutil.rmtree(work, ignore_errors=True)
        else:
            print(f"kept {work}")
    print(f"cluster sessions check: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
