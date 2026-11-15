#!/usr/bin/env python3
"""The chaos harness (ADR-0065, M6 item 9): a cluster of real nodes behind a proxy of our own, clients racing on a few
keys, faults injected (kills, pauses, partitions), and the history checked for linearizability, per key.

usage:
  cluster_chaos.py [--binary out/cosmostore] [--nodes 3] [--seconds 60] [--seed N] [--port-base 20100]
                   [--clients 6] [--keys 4] [--keep] [--nemesis kill,pause,isolate,isolate-leader,split,bridge]
  cluster_chaos.py --self-test          the checker against histories whose answer is known

Standard library only; no firewall rule, nothing installed. Exit status 0 when the history is linearizable and the
cluster answered after the faults were healed.
"""
import argparse
import datetime
import hashlib
import hmac
import http.client
import json
import os
import random
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

REGION = "us-east-1"
ACCESS = "AKIACLUSTERCHAOS0001"
SECRET = "clusterchaossecret0123456"
BUCKET = "chaos"

# ---------------------------------------------------------------------------------------------------------------------
# The checker: Wing-Gong-Lowe search with memoization, per key, against a register (a value, or None for absent).

INF = float("inf")


class Op:
    __slots__ = ("id", "kind", "value", "start", "end", "client", "note")

    def __init__(self, kind, value, start, end, client=-1, note=""):
        self.id = 0
        self.kind = kind  # "w" write value (None: delete), "r" read value (None: absent), "p" read presence (bool)
        self.value = value
        self.start = start
        self.end = end  # INF: unknown outcome
        self.client = client
        self.note = note

    def __repr__(self):
        end = "?" if self.end == INF else f"{self.end:.3f}"
        return f"{self.note or self.kind}({self.value!r}) [{self.start:.3f}, {end}] c{self.client}"


def step(state, op):
    if op.kind == "w":
        return True, op.value
    if op.kind == "r":
        return state == op.value, state
    return (state is not None) == op.value, state


def prune(ops, keep_unseen, window=None):
    """Unknown writes whose value no read saw (ADR-0065 §5). Against reads of a value they can only stand in the way,
    and are left out. A listing sees only that the key is there, which any of them explains; and one that began
    earlier can stand in for one that began later (its end is open), so the earliest few are kept. Leaving an
    operation out can only make a history harder to explain: a pruned history that is linearizable is one."""
    seen = {op.value for op in ops if op.kind == "r" and op.value is not None}
    listed = any(op.kind == "p" and op.value for op in ops)
    unseen = sorted((op for op in ops if op.kind == "w" and op.end == INF and op.value is not None
                     and op.value not in seen), key=lambda o: o.start)
    if window is not None:
        unseen = [op for op in unseen if window[0] <= op.start <= window[1]]
    keep = {id(op) for op in unseen[:keep_unseen]} if listed else set()
    out = []
    for op in ops:
        if op.kind == "w" and op.end == INF and op.value is not None and op.value not in seen and id(op) not in keep:
            continue
        out.append(op)
    return out


def linearizable(ops, initial=None):
    """`search` with one unseen unknown write kept, then, if that finds no order, with all of them (`prune`): the
    first is quick; the second settles what the first could not, within the search's limit. (True, None), (False,
    the operation no order gets past), or (None, why) when the search was too large to settle it."""
    good, at = search(ops, initial, 1)
    if good:
        return True, None
    # The unseen writes that began in the seconds before the operation no order got past.
    try:
        again, at2 = search(ops, initial, len(ops), (at.start - UNSEEN_WINDOW_S, at.end))
    except RuntimeError as e:
        return None, str(e)
    return (True, None) if again else (False, at2 or at)


UNSEEN_WINDOW_S = 5.0


def search(ops, initial, keep_unseen, window=None):
    """Whether `ops` (one key's) have a linearization from `initial`. Unknown ones (end INF) may be left out. When
    not, the operation the longest partial linearization could not get past: no order puts it there."""
    ops = prune(ops, keep_unseen, window)
    for i, op in enumerate(ops):
        op.id = i
    # Entries: (time, is_return, op); calls before returns at equal times.
    events = []
    for op in ops:
        events.append((op.start, 0, op))
        events.append((op.end, 1, op))
    events.sort(key=lambda e: (e[0], e[1], e[2].id))
    n = len(events)
    # A doubly linked list over the events: node 0 is the head, 1..n the events in order, n + 1 the end.
    ret_of = {}
    call_at = [None] * (n + 1)
    for i, (_, is_ret, op) in enumerate(events):
        call_at[i + 1] = (is_ret, op)
        if is_ret:
            ret_of[op.id] = i + 1
    prev = [i - 1 for i in range(n + 2)]
    nxt = [i + 1 for i in range(n + 2)]

    def lift(c):
        r = ret_of[call_at[c][1].id]
        nxt[prev[c]] = nxt[c]
        prev[nxt[c]] = prev[c]
        nxt[prev[r]] = nxt[r]
        prev[nxt[r]] = prev[r]

    def unlift(c):
        r = ret_of[call_at[c][1].id]
        prev[nxt[r]] = r
        nxt[prev[r]] = r
        prev[nxt[c]] = c
        nxt[prev[c]] = c

    cache = set()
    calls = []
    state = initial
    done = 0  # bitset of linearized ops
    entry = nxt[0]
    steps = 0
    # For the report: the furthest the search got, and the operation it could not get past there.
    deepest, stuck = -1, None
    while entry != n + 1:
        steps += 1
        if steps > 20_000_000:
            raise RuntimeError("the search is too large")
        is_ret, op = call_at[entry]
        if not is_ret:
            ok, after = step(state, op)
            if ok:
                bits = done | (1 << op.id)
                memo = (bits, after)
                if memo not in cache:
                    cache.add(memo)
                    calls.append((entry, state))
                    state = after
                    done = bits
                    lift(entry)
                    entry = nxt[0]
                    continue
            entry = nxt[entry]
        else:
            # Every finite return before this one is linearized; from here on only unknown ones are left.
            if op.end == INF:
                return True, None
            if len(calls) > deepest:
                deepest, stuck = len(calls), op
            if not calls:
                return False, stuck
            entry, state = calls.pop()
            done &= ~(1 << call_at[entry][1].id)
            unlift(entry)
            entry = nxt[entry]
    return True, None


def self_test():
    def w(v, s, e):
        return Op("w", v, s, e)

    def r(v, s, e):
        return Op("r", v, s, e)

    def p(v, s, e):
        return Op("p", v, s, e)

    cases = [
        ("sequential", [w("a", 0, 1), r("a", 2, 3), w("b", 4, 5), r("b", 6, 7)], True),
        ("a stale read", [w("a", 0, 1), w("b", 2, 3), r("a", 4, 5)], False),
        ("concurrent reads either way", [w("a", 0, 1), w("b", 2, 6), r("b", 3, 4), r("b", 5, 7)], True),
        ("new then old: not linearizable", [w("a", 0, 1), w("b", 2, 6), r("b", 3, 4), r("a", 5, 7)], False),
        ("a value never written", [w("a", 0, 1), r("z", 2, 3)], False),
        ("an acknowledged write lost", [w("a", 0, 1), w("b", 2, 3), r(None, 4, 5)], False),
        ("an unknown write seen", [w("a", 0, 1), w("b", 2, INF), r("b", 5, 6), r("b", 7, 8)], True),
        ("an unknown write not seen", [w("a", 0, 1), w("b", 2, INF), r("a", 5, 6)], True),
        ("an unknown write seen, then unseen", [w("a", 0, 1), w("b", 2, INF), r("b", 5, 6), r("a", 7, 8)], False),
        ("an unknown delete", [w("a", 0, 1), w(None, 2, INF), r(None, 3, 4)], True),
        ("a delete then a stale read", [w("a", 0, 1), w(None, 2, 3), r("a", 4, 5)], False),
        ("a listing misses a present key", [w("a", 0, 1), p(False, 2, 3)], False),
        ("a listing sees a deleted key", [w("a", 0, 1), w(None, 2, 3), p(True, 4, 5)], False),
        ("a listing, concurrent with the write", [p(True, 0, 5), w("a", 1, 2), p(True, 6, 7)], True),
        ("a listing explained by an unknown write no read saw",
         [w("a", 0, 1), w(None, 2, 3), p(False, 4, 5), w("b", 4.5, INF), p(True, 6, 7)], True),
        ("a listing after the delete, with no write to explain it",
         [w("a", 0, 1), w(None, 2, 3), p(False, 4, 5), p(True, 6, 7)], False),
    ]
    # A larger random history from a real register: linearizable by construction.
    rng = random.Random(7)
    big = []
    t = 0.0
    state = None
    for i in range(3000):
        start = t
        t += rng.random()
        if rng.random() < 0.5:
            v = f"v{i}"
            big.append(w(v, start, t))
            state = v
        else:
            big.append(r(state, start, t))
        t += rng.random() * 0.1
    cases.append(("3000 sequential operations", big, True))
    failures = 0
    for name, ops, want in cases:
        got, _ = linearizable(ops)
        print(("ok  " if got is want else "FAIL"), name)
        failures += got is not want
    print(f"checker self-test: {len(cases) - failures} passed, {failures} failed")
    return failures == 0


# ---------------------------------------------------------------------------------------------------------------------
# SigV4 and the S3 client.


def _sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def authorize(method, host, path, query, headers, body):
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date = amz_date[:8]
    payload_hash = hashlib.sha256(body).hexdigest()
    headers = dict(headers)
    headers["host"] = host
    headers["x-amz-date"] = amz_date
    headers["x-amz-content-sha256"] = payload_hash
    names = sorted(headers)
    canonical = "\n".join([
        method, path, query,
        "".join(f"{n}:{headers[n].strip()}\n" for n in names),
        ";".join(names), payload_hash,
    ])
    scope = f"{date}/{REGION}/s3/aws4_request"
    sts = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    key = _sign(_sign(_sign(_sign(("AWS4" + SECRET).encode(), date), REGION), "s3"), "aws4_request")
    signature = hmac.new(key, sts.encode(), hashlib.sha256).hexdigest()
    headers["authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={ACCESS}/{scope}, SignedHeaders={';'.join(names)}, Signature={signature}"
    )
    return headers


def s3(port, method, path, query="", body=b"", timeout=4.0):
    """(status, body), or (None, reason) when no answer came."""
    host = f"127.0.0.1:{port}"
    headers = authorize(method, host, path, query, {}, body)
    try:
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
        c.request(method, path + ("?" + query if query else ""), body=body, headers=headers)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, data
    except (OSError, http.client.HTTPException) as e:
        return None, str(e)


# ---------------------------------------------------------------------------------------------------------------------
# The proxy (ADR-0065 §2).


class Proxy:
    def __init__(self, fronts):
        self.fronts = fronts  # node -> (proxy port, real port)
        self.cut = set()  # frozenset({a, b})
        self.lock = threading.Lock()
        self.conns = []  # (sender, node, client socket, upstream socket)
        self.stopping = False
        self.listeners = []

    def start(self):
        for node, (front, real) in self.fronts.items():
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", front))
            s.listen(128)
            self.listeners.append(s)
            threading.Thread(target=self._accept, args=(s, node, real), daemon=True).start()

    def stop(self):
        self.stopping = True
        for s in self.listeners:
            try:
                s.close()
            except OSError:
                pass
        self.partition(set())

    def blocked(self, a, b):
        return a != 0 and frozenset((a, b)) in self.cut

    def partition(self, cut):
        with self.lock:
            self.cut = set(cut)
            keep = []
            for c in self.conns:
                sender, node, down, up = c
                if self.blocked(sender, node) or self.stopping:
                    for x in (down, up):
                        try:
                            x.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass
                        x.close()
                else:
                    keep.append(c)
            self.conns = keep

    def _accept(self, s, node, real):
        while not self.stopping:
            try:
                down, _ = s.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(down, node, real), daemon=True).start()

    def _serve(self, down, node, real):
        down.settimeout(10)
        head = b""
        try:
            while b"\r\n\r\n" not in head and len(head) < 65536:
                chunk = down.recv(65536)
                if not chunk:
                    down.close()
                    return
                head += chunk
        except OSError:
            down.close()
            return
        m = re.search(rb"(?im)^x-cosmo-node:\s*(\d+)", head)
        sender = int(m.group(1)) if m else 0
        with self.lock:
            if self.blocked(sender, node) or self.stopping:
                down.close()
                return
        try:
            up = socket.create_connection(("127.0.0.1", real), timeout=5)
        except OSError:
            down.close()
            return
        down.settimeout(None)
        up.settimeout(None)
        with self.lock:
            if self.blocked(sender, node):
                down.close()
                up.close()
                return
            self.conns.append((sender, node, down, up))
        try:
            up.sendall(head)
        except OSError:
            pass
        threading.Thread(target=self._pipe, args=(up, down), daemon=True).start()
        self._pipe(down, up)

    @staticmethod
    def _pipe(a, b):
        try:
            while True:
                data = a.recv(65536)
                if not data:
                    break
                b.sendall(data)
        except OSError:
            pass
        for x in (a, b):
            try:
                x.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


# ---------------------------------------------------------------------------------------------------------------------
# The cluster.


class Cluster:
    def __init__(self, binary, work, nodes, base):
        self.binary = binary
        self.work = work
        self.n = nodes
        self.base = base
        self.procs = {}
        self.paused = set()
        self.conf = os.path.join(work, "cluster.conf")
        with open(os.path.join(work, "credentials"), "w") as f:
            f.write(f"{ACCESS} {SECRET}\n")
        with open(os.path.join(work, "cluster.key"), "w") as f:
            f.write(__import__("base64").b64encode(os.urandom(32)).decode() + "\n")
        lines = ["cluster 0dd0ee0ff0aa0bb0", "shards 2", "replicas 3", f"secret-file {work}/cluster.key"]
        domains = "abcdefgh"
        for i in range(1, nodes + 1):
            lines.append(f"node {i} peer=127.0.0.1:{self.proxy_port(i)} domain={domains[i - 1]}")
        with open(self.conf, "w") as f:
            f.write("\n".join(lines) + "\n")

    def proxy_port(self, i):
        return self.base + i

    def s3_port(self, i):
        return self.base + 20 + i

    def peer_port(self, i):
        return self.base + 40 + i

    def start(self, i):
        d = os.path.join(self.work, f"d{i}")
        os.makedirs(d, exist_ok=True)
        log = open(os.path.join(self.work, f"log{i}"), "ab")
        self.procs[i] = subprocess.Popen(
            [self.binary, "node", d, "--cluster-file", self.conf, "--node", str(i),
             "--listen", str(self.s3_port(i)), "--credentials", os.path.join(self.work, "credentials"),
             "--peer-listen", str(self.peer_port(i))],
            stdout=log, stderr=log)
        self.paused.discard(i)

    def kill(self, i):
        p = self.procs.get(i)
        if p and p.poll() is None:
            if i in self.paused:
                p.send_signal(signal.SIGCONT)
            p.kill()
            p.wait()
        self.paused.discard(i)

    def pause(self, i):
        p = self.procs.get(i)
        if p and p.poll() is None:
            p.send_signal(signal.SIGSTOP)
            self.paused.add(i)

    def resume(self, i):
        p = self.procs.get(i)
        if p and p.poll() is None and i in self.paused:
            p.send_signal(signal.SIGCONT)
        self.paused.discard(i)

    def stop_all(self):
        for i in list(self.procs):
            self.kill(i)

    def status_text(self, i):
        try:
            return subprocess.run([self.binary, "cluster-status", "--cluster-file", self.conf, "--node", str(i)],
                                  capture_output=True, text=True, timeout=5).stdout
        except subprocess.TimeoutExpired:
            return "(no answer in 5 s)\n"

    def status(self, i):
        """[(shard, role, term, leader, last, commit, applied)] as node i reports them, or []."""
        try:
            out = subprocess.run([self.binary, "cluster-status", "--cluster-file", self.conf, "--node", str(i)],
                                 capture_output=True, text=True, timeout=5).stdout
        except subprocess.TimeoutExpired:
            return []
        rows = []
        for line in out.splitlines()[1:]:
            f = line.split()
            if len(f) >= 7 and f[0].isdigit():
                rows.append(f)
        return rows

    def leaders(self):
        for i in range(1, self.n + 1):
            if i in self.paused or self.procs.get(i) is None or self.procs[i].poll() is not None:
                continue
            rows = self.status(i)
            if rows:
                return {int(r[0]): int(r[3]) for r in rows}
        return {}


# ---------------------------------------------------------------------------------------------------------------------
# The run.


class History:
    def __init__(self):
        self.lock = threading.Lock()
        self.t0 = time.monotonic()
        self.events = []  # dicts

    def now(self):
        return time.monotonic() - self.t0

    def add(self, e):
        with self.lock:
            self.events.append(e)


def value_of(body):
    """The value a GET read: the write's tag, the first line of its body."""
    return body.split(b"\n", 1)[0].decode(errors="replace")


def client(cid, cluster, history, keys, rng, stop, counts):
    seq = 0
    while not stop.is_set():
        node = rng.randint(1, cluster.n)
        port = cluster.s3_port(node)
        key = rng.choice(keys)
        roll = rng.random()
        start = history.now()
        if roll < 0.40:
            seq += 1
            tag = f"c{cid}-{seq}"
            body = (tag + "\n").encode()
            if rng.random() < 0.1:
                body += os.urandom(300_000)  # an extent's worth (ADR-0061)
            status, _ = s3(port, "PUT", f"/{BUCKET}/{key}", body=body)
            outcome = "ok" if status == 200 else ("fail" if status is not None and 400 <= status < 500 else "unknown")
            history.add(dict(c=cid, n=node, op="put", key=key, value=tag, start=start, end=history.now(),
                             outcome=outcome, status=status))
        elif roll < 0.45:
            status, _ = s3(port, "DELETE", f"/{BUCKET}/{key}")
            outcome = "ok" if status == 204 else ("fail" if status is not None and 400 <= status < 500 else "unknown")
            history.add(dict(c=cid, n=node, op="delete", key=key, value=None, start=start, end=history.now(),
                             outcome=outcome, status=status))
        elif roll < 0.90:
            status, data = s3(port, "GET", f"/{BUCKET}/{key}")
            if status == 200:
                history.add(dict(c=cid, n=node, op="get", key=key, value=value_of(data), start=start,
                                 end=history.now(), outcome="ok", status=status))
            elif status == 404 and b"NoSuchKey" in data:
                history.add(dict(c=cid, n=node, op="get", key=key, value=None, start=start, end=history.now(),
                                 outcome="ok", status=status))
            else:
                counts["reads without an answer"] = counts.get("reads without an answer", 0) + 1
        else:
            status, data = s3(port, "GET", f"/{BUCKET}", query="list-type=2&prefix=k")
            if status == 200:
                present = re.findall(rb"<Key>([^<]*)</Key>", data)
                history.add(dict(c=cid, n=node, op="list", key=None,
                                 value=sorted(k.decode() for k in present), start=start, end=history.now(),
                                 outcome="ok", status=status))
            else:
                counts["lists without an answer"] = counts.get("lists without an answer", 0) + 1


NEMESES = ["kill", "pause", "isolate", "isolate-leader", "split", "bridge"]


def nemesis(cluster, proxy, rng, stop, log, history, kinds):
    others = lambda i: [j for j in range(1, cluster.n + 1) if j != i]
    while not stop.is_set():
        if stop.wait(rng.uniform(1.0, 3.0)):
            break
        kind = rng.choice(kinds)
        victim = rng.randint(1, cluster.n)
        if kind == "isolate-leader":
            leaders = {s: l for s, l in cluster.leaders().items() if s != 65535 and l != 0}
            if leaders:
                victim = rng.choice(sorted(leaders.values()))
            kind = "isolate"
        hold = rng.uniform(2.0, 6.0)
        t = history.now()
        if kind == "kill":
            log.append(f"{t:8.3f} kill node {victim}")
            cluster.kill(victim)
            stop.wait(hold)
            cluster.start(victim)
        elif kind == "pause":
            log.append(f"{t:8.3f} pause node {victim}")
            cluster.pause(victim)
            stop.wait(hold)
            cluster.resume(victim)
        else:
            if kind == "isolate":
                cut = {frozenset((victim, j)) for j in others(victim)}
                what = f"isolate node {victim}"
            elif kind == "split":
                nodes = list(range(1, cluster.n + 1))
                rng.shuffle(nodes)
                small = nodes[: (cluster.n - 1) // 2]
                cut = {frozenset((a, b)) for a in small for b in nodes if b not in small}
                what = f"split {sorted(small)} from the rest"
            else:
                # A bridge: two sides that do not see each other, and one node that sees both.
                nodes = list(range(1, cluster.n + 1))
                rng.shuffle(nodes)
                bridge, rest = nodes[0], nodes[1:]
                left, right = rest[: len(rest) // 2], rest[len(rest) // 2:]
                cut = {frozenset((a, b)) for a in left for b in right}
                what = f"bridge {bridge} between {sorted(left)} and {sorted(right)}"
            log.append(f"{t:8.3f} {what}")
            proxy.partition(cut)
            stop.wait(hold)
            proxy.partition(set())
        log.append(f"{history.now():8.3f} healed")


def ops_by_key(events, keys):
    per = {k: [] for k in keys}
    for e in events:
        end = e["end"] if e["outcome"] == "ok" else INF
        if e["outcome"] == "fail":
            continue
        note = f"{e['op']}@n{e['n']}"
        if e["op"] == "put":
            per[e["key"]].append(Op("w", e["value"], e["start"], end, e["c"], note))
        elif e["op"] == "delete":
            per[e["key"]].append(Op("w", None, e["start"], end, e["c"], note))
        elif e["op"] == "get":
            per[e["key"]].append(Op("r", e["value"], e["start"], end, e["c"], note))
        elif e["op"] == "list":
            for k in keys:
                per[k].append(Op("p", k in e["value"], e["start"], end, e["c"], note))
    return per


def run(args):
    binary = os.path.abspath(args.binary)
    work = tempfile.mkdtemp(prefix="cosmo-chaos-")
    seed = args.seed if args.seed is not None else random.randrange(1 << 30)
    print(f"chaos: seed {seed}, {args.nodes} nodes, {args.seconds} s, work {work}")
    rng = random.Random(seed)
    for k in args.nemesis.split(","):
        if k not in NEMESES:
            print(f"chaos: no fault called {k}; there are {', '.join(NEMESES)}")
            return False
    cluster = Cluster(binary, work, args.nodes, args.port_base)
    proxy = Proxy({i: (cluster.proxy_port(i), cluster.peer_port(i)) for i in range(1, args.nodes + 1)})
    proxy.start()
    ok = False
    try:
        for i in range(1, args.nodes + 1):
            cluster.start(i)
        deadline = time.time() + 30
        while time.time() < deadline:
            rows = cluster.status(1)
            if rows and all(r[3] != "0" for r in rows):
                break
            time.sleep(0.2)
        status, data = None, b""
        for _ in range(50):
            status, data = s3(cluster.s3_port(1), "PUT", f"/{BUCKET}")
            if status == 200:
                break
            time.sleep(0.2)
        if status != 200:
            print(f"FAIL the bucket could not be made: {status} {data[:200]!r}")
            return False
        keys = [f"k{i}" for i in range(args.keys)]
        history = History()
        counts = {}
        stop = threading.Event()
        log = []
        threads = [threading.Thread(target=client,
                                    args=(c, cluster, history, keys, random.Random(seed * 31 + c), stop, counts))
                   for c in range(args.clients)]
        threads.append(threading.Thread(target=nemesis, args=(cluster, proxy, rng, stop, log, history, args.nemesis.split(","))))
        for t in threads:
            t.start()
        time.sleep(args.seconds)
        stop.set()
        for t in threads:
            t.join()
        # Healed: every node up, no partition; then every key read through every node.
        proxy.partition(set())
        for i in range(1, args.nodes + 1):
            if cluster.procs[i].poll() is not None:
                cluster.start(i)
            cluster.resume(i)
        log.append(f"{history.now():8.3f} all healed")
        unanswered = []
        for k in keys:
            for i in range(1, args.nodes + 1):
                answered = False
                began = time.time()
                deadline = began + 30
                noted = False
                while time.time() < deadline:
                    if not noted and time.time() - began > 5:
                        # Slow to come back: what each node thinks, for the report.
                        noted = True
                        with open(os.path.join(work, "status-after-heal.txt"), "a") as f:
                            f.write(f"--- {history.now():.3f} waiting on {k} through node {i}\n")
                            for j in range(1, args.nodes + 1):
                                f.write(f"node {j}:\n" + cluster.status_text(j))
                        # Where each node's threads are (macOS `sample`; elsewhere nothing).
                        if shutil.which("sample"):
                            for j in range(1, args.nodes + 1):
                                p = cluster.procs.get(j)
                                if p and p.poll() is None:
                                    subprocess.run(["sample", str(p.pid), "1", "-file",
                                                    os.path.join(work, f"sample-node{j}.txt")],
                                                   capture_output=True, timeout=30)
                    start = history.now()
                    status, data = s3(cluster.s3_port(i), "GET", f"/{BUCKET}/{k}", timeout=5)
                    if status == 200 or (status == 404 and b"NoSuchKey" in data):
                        history.add(dict(c=-1, n=i, op="get", key=k,
                                         value=value_of(data) if status == 200 else None, start=start,
                                         end=history.now(), outcome="ok", status=status))
                        answered = True
                        break
                    time.sleep(0.5)
                if not answered:
                    unanswered.append(f"{k} through node {i}")
        with open(os.path.join(work, "history.jsonl"), "w") as f:
            for e in history.events:
                f.write(json.dumps(e) + "\n")
        with open(os.path.join(work, "nemesis.log"), "w") as f:
            f.write("\n".join(log) + "\n")
        done = sum(1 for e in history.events if e["outcome"] == "ok")
        unknown = sum(1 for e in history.events if e["outcome"] == "unknown")
        failed = sum(1 for e in history.events if e["outcome"] == "fail")
        writes = sum(1 for e in history.events if e["op"] in ("put", "delete") and e["outcome"] == "ok")
        print(f"chaos: {len(history.events)} operations ({done} done, {writes} of them writes; {unknown} unknown, "
              f"{failed} refused); {sum(counts.values())} reads and lists without an answer; "
              f"{sum(1 for x in log if 'healed' not in x)} faults")
        for line in log:
            print("  " + line)
        ok = True
        if unanswered:
            print("FAIL after the heal, no answer for: " + ", ".join(unanswered))
            ok = False
        # A replica that stopped itself (a journal it found corrupt, a failed write) is a failure of its own.
        for i in range(1, args.nodes + 1):
            with open(os.path.join(work, f"log{i}"), errors="replace") as f:
                for line in f:
                    if "stopped" in line or "panic" in line:
                        print(f"FAIL node {i}: {line.strip()}")
                        ok = False
        per = ops_by_key(history.events, keys)
        for k in keys:
            good, at = linearizable(per[k])
            if good:
                print(f"ok   {k}: {len(per[k])} operations, linearizable")
            elif good is None:
                ok = False
                print(f"FAIL {k}: not settled ({at}): no order was found with one unseen write kept")
            else:
                ok = False
                print(f"FAIL {k}: not linearizable; the longest order explains everything before {at!r}, not it. "
                      "Around it:")
                for op in sorted(per[k], key=lambda o: o.start):
                    wrote_it = at.kind == "r" and op.kind == "w" and op.value == at.value and op is not at
                    if wrote_it or op is at or -1.0 < op.start - at.start < 0.2:
                        print(f"       {'>' if op is at else ' '} {op!r}{'   (the write it read)' if wrote_it else ''}")
        return ok
    finally:
        proxy.stop()
        cluster.stop_all()
        if ok and not args.keep:
            shutil.rmtree(work, ignore_errors=True)
        else:
            print(f"chaos: kept {work}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--binary", default="out/cosmostore")
    p.add_argument("--nodes", type=int, default=3)
    p.add_argument("--seconds", type=float, default=60)
    p.add_argument("--seed", type=int)
    p.add_argument("--port-base", type=int, default=20100)
    p.add_argument("--clients", type=int, default=6)
    p.add_argument("--keys", type=int, default=4)
    p.add_argument("--keep", action="store_true")
    p.add_argument("--nemesis", default=",".join(NEMESES), help="the faults to choose from, by name, with commas")
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args()
    if args.self_test:
        sys.exit(0 if self_test() else 1)
    sys.exit(0 if run(args) else 1)


if __name__ == "__main__":
    main()
