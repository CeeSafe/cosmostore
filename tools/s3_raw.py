#!/usr/bin/env python3
"""A raw SigV4 S3 client for what the AWS CLI does not do (ADR-0008 tests), standard library only.

usage:
  s3_raw.py chunked-put  ENDPOINT BUCKET KEY FILE [CHUNK]   signed aws-chunked PUT (STREAMING-AWS4-HMAC-SHA256-PAYLOAD)
  s3_raw.py bad-chunk    ENDPOINT BUCKET KEY FILE           the same with one data byte changed: expects 403
  s3_raw.py abort-get    ENDPOINT BUCKET KEY BYTES          reads BYTES of a GET, then drops the connection
  s3_raw.py presign      ENDPOINT METHOD BUCKET KEY SECONDS prints a presigned URL (query auth, ADR-0011)

Credentials come from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY; the region is us-east-1.
"""
import datetime
import hashlib
import hmac
import os
import socket
import sys
import urllib.parse

REGION = "us-east-1"


def sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def signing_key(secret, date):
    k = sign(("AWS4" + secret).encode(), date)
    k = sign(k, REGION)
    k = sign(k, "s3")
    return sign(k, "aws4_request")


def authorize(method, host, path, headers, payload_hash):
    access = os.environ["AWS_ACCESS_KEY_ID"]
    secret = os.environ["AWS_SECRET_ACCESS_KEY"]
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date = amz_date[:8]
    headers = dict(headers)
    headers["host"] = host
    headers["x-amz-date"] = amz_date
    headers["x-amz-content-sha256"] = payload_hash
    names = sorted(headers)
    canonical = "\n".join([
        method,
        path,
        "",
        "".join(f"{n}:{headers[n].strip()}\n" for n in names),
        ";".join(names),
        payload_hash,
    ])
    scope = f"{date}/{REGION}/s3/aws4_request"
    sts = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    key = signing_key(secret, date)
    signature = hmac.new(key, sts.encode(), hashlib.sha256).hexdigest()
    headers["authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={access}/{scope}, SignedHeaders={';'.join(names)}, Signature={signature}"
    )
    return headers, key, amz_date, scope, signature


def connect(endpoint):
    u = urllib.parse.urlparse(endpoint)
    return socket.create_connection((u.hostname, u.port or 80)), f"{u.hostname}:{u.port or 80}"


def read_response(s):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    status = int(lines[0].split()[1])
    fields = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
    length = int(fields.get("content-length", "0"))
    while len(rest) < length:
        chunk = s.recv(65536)
        if not chunk:
            break
        rest += chunk
    return status, fields, rest


def chunked_put(endpoint, bucket, key, path, chunk=65536, corrupt=False):
    data = open(path, "rb").read()
    s, host = connect(endpoint)
    target = "/" + bucket + "/" + urllib.parse.quote(key, safe="/~")
    chunks = [data[i:i + chunk] for i in range(0, len(data), chunk)] + [b""]
    sig_len = 64
    body_len = sum(len(f"{len(c):x};chunk-signature=") + sig_len + 2 + len(c) + 2 for c in chunks)
    headers = {
        "content-encoding": "aws-chunked",
        "x-amz-decoded-content-length": str(len(data)),
        "content-length": str(body_len),
    }
    headers, skey, amz_date, scope, previous = authorize(
        "PUT", host, target, headers, "STREAMING-AWS4-HMAC-SHA256-PAYLOAD")
    body = b""
    empty = hashlib.sha256(b"").hexdigest()
    for c in chunks:
        sts = "\n".join(["AWS4-HMAC-SHA256-PAYLOAD", amz_date, scope, previous, empty, hashlib.sha256(c).hexdigest()])
        previous = hmac.new(skey, sts.encode(), hashlib.sha256).hexdigest()
        body += f"{len(c):x};chunk-signature={previous}\r\n".encode() + c + b"\r\n"
    assert len(body) == body_len
    if corrupt and len(data) > 0:
        at = body.index(b"\r\n") + 2 + len(data[:chunk]) // 2
        body = body[:at] + bytes([body[at] ^ 1]) + body[at + 1:]
    request = f"PUT {target} HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in headers.items()) + "\r\n"
    s.sendall(request.encode() + body)
    status, fields, rest = read_response(s)
    s.close()
    return status, fields.get("etag", ""), rest


def abort_get(endpoint, bucket, key, nbytes):
    s, host = connect(endpoint)
    target = "/" + bucket + "/" + urllib.parse.quote(key, safe="/~")
    headers, *_ = authorize("GET", host, target, {}, hashlib.sha256(b"").hexdigest())
    request = f"GET {target} HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in headers.items()) + "\r\n"
    s.sendall(request.encode())
    got = b""
    while len(got) < nbytes:
        chunk = s.recv(16384)
        if not chunk:
            break
        got += chunk
    s.close()
    return got[:12]


def presign(endpoint, method, bucket, key, seconds):
    access = os.environ["AWS_ACCESS_KEY_ID"]
    secret = os.environ["AWS_SECRET_ACCESS_KEY"]
    host = urllib.parse.urlsplit(endpoint).netloc
    amz_date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    date = amz_date[:8]
    scope = f"{date}/{REGION}/s3/aws4_request"
    path = "/" + bucket + "/" + urllib.parse.quote(key, safe="/~")
    params = {
        "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
        "X-Amz-Credential": f"{access}/{scope}",
        "X-Amz-Date": amz_date,
        "X-Amz-Expires": str(seconds),
        "X-Amz-SignedHeaders": "host",
    }
    query = "&".join(f"{urllib.parse.quote(k, safe='~')}={urllib.parse.quote(v, safe='~')}" for k, v in sorted(params.items()))
    canonical = "\n".join([method, path, query, f"host:{host}\n", "host", "UNSIGNED-PAYLOAD"])
    sts = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    signature = hmac.new(signing_key(secret, date), sts.encode(), hashlib.sha256).hexdigest()
    return f"{endpoint}{path}?{query}&X-Amz-Signature={signature}"


def main():
    cmd = sys.argv[1]
    if cmd in ("chunked-put", "bad-chunk"):
        chunk = int(sys.argv[6]) if len(sys.argv) > 6 else 65536
        status, etag, rest = chunked_put(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], chunk, cmd == "bad-chunk")
        print(status, etag)
        if status >= 300:
            print(rest.decode(errors="replace"))
    elif cmd == "presign":
        print(presign(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])))
    elif cmd == "abort-get":
        print(abort_get(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
