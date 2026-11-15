#!/usr/bin/env python3
"""The chaos harness (ADR-0065, M6 item 9): a cluster of real nodes behind a proxy of our own, clients racing on a few
keys, faults injected (kills, pauses, partitions), and the history checked for linearizability, per key.

usage:
  cluster_chaos.py [--binary out/cosmostore] [--nodes 3] [--seconds 60] [--seed N] [--port-base 20100]
                   [--clients 6] [--keys 4] [--keep] [--disk-loss | --racks 3]
                   [--nemesis kill,pause,isolate,isolate-leader,split,bridge,skew,lose-disk]
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
    __slots__ = ("id", "kind", "value", "start", "end", "client", "note", "key")

    def __init__(self, kind, value, start, end, client=-1, note="", key=0):
        self.id = 0
        self.key = key  # the key's index, for the check across keys
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


def step_all(state, op):
    """The registers of every key at once, a tuple: a listing ("L") sees the exact set of keys present at one moment."""
    if op.kind == "w":
        return True, state[:op.key] + (op.value,) + state[op.key + 1:]
    if op.kind == "r":
        return state[op.key] == op.value, state
    return frozenset(i for i, v in enumerate(state) if v is not None) == op.value, state


def linearizable_all(per_key, lists, keys):
    """The history of every key together (ADR-0065 §5, the exit review's gap): each key's writes and reads, pruned as
    its own check prunes them, and each listing as one operation that saw every key's presence at a single moment.
    The same two tiers as `linearizable`: (True, None), (False, the operation no order gets past), or (None, why)."""
    def gather(keep_unseen, window):
        ops = []
        for i, k in enumerate(keys):
            for op in prune(per_key[k], keep_unseen, window):
                if op.kind != "p":
                    op.key = i
                    ops.append(op)
        return ops + lists
    initial = tuple(None for _ in keys)
    good, at = search(gather(1, None), initial, 0, None, step_all, prepared=True)
    if good:
        return True, None
    try:
        again, at2 = search(gather(10**9, (at.start - UNSEEN_WINDOW_S, at.end)), initial, 0, None, step_all,
                            prepared=True)
    except RuntimeError as e:
        return None, str(e)
    return (True, None) if again else (False, at2 or at)


def search(ops, initial, keep_unseen, window=None, stepper=step, prepared=False):
    """Whether `ops` (one key's) have a linearization from `initial`. Unknown ones (end INF) may be left out. When
    not, the operation the longest partial linearization could not get past: no order puts it there."""
    if not prepared:
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
            ok, after = stepper(state, op)
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
    # Across keys: a listing that saw k0 before its delete and k1 after its write, which no single moment had.
    def wk(k, v, s, e):
        return Op("w", v, s, e, key=k)

    def listing(present, s, e):
        return Op("L", frozenset(present), s, e)

    across = [
        ("a listing that is one moment", [wk(0, "a", 0, 1), wk(1, "b", 2, 3), listing({0, 1}, 4, 5)], True),
        ("a listing of two moments", [wk(0, "a", 0, 1), wk(0, None, 2, 3), wk(1, "b", 4, 5),
                                       listing({0, 1}, 0.5, 6)], False),
        ("a listing concurrent with both", [wk(0, "a", 0, 1), wk(0, None, 2, 6), wk(1, "b", 3, 5),
                                             listing({0, 1}, 0.5, 7)], True),
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
    for name, ops, want in across:
        got, _ = search(ops, (None, None), 0, None, step_all, prepared=True)
        print(("ok  " if got is want else "FAIL"), name)
        failures += got is not want
    cases = cases + across
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
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        c.request(method, path + ("?" + query if query else ""), body=body, headers=headers)
        r = c.getresponse()
        data = r.read()
        return r.status, data
    except (OSError, http.client.HTTPException) as e:
        return None, str(e)
    finally:
        c.close()


# ---------------------------------------------------------------------------------------------------------------------
# The proxy (ADR-0065 §2).


class Proxy:
    def __init__(self, fronts):
        self.fronts = fronts  # node -> (proxy port, real port)
        self.cut = set()  # frozenset({a, b})
        # Links shaped (ADR-0069 §1): per node (0: every link), a delay and jitter in seconds, a chance of a reset at
        # each chunk, a bandwidth in bytes a second (0: none).
        self.shape = {}
        self.rng = random.Random(1)
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
        if not cut:
            self.shape.clear()
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
                if self.stopping:
                    return
                # Out of descriptors, or a connection reset before it was taken: the port stays open (a proxy that
                # stopped taking connections would look like a cluster that stopped answering).
                time.sleep(0.05)
                continue
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
        entry = (sender, node, down, up)
        try:
            up.sendall(head)
        except OSError:
            pass
        back = threading.Thread(target=self._pipe, args=(up, down, sender, node), daemon=True)
        back.start()
        self._pipe(down, up, sender, node)
        back.join()
        # Both ways done: the sockets closed and forgotten, so that a long run does not run out of descriptors.
        with self.lock:
            if entry in self.conns:
                self.conns.remove(entry)
        for x in (down, up):
            try:
                x.close()
            except OSError:
                pass

    def shaping(self, sender, node):
        """The shape of the link between `sender` and `node`: the strongest of every link's and either end's."""
        delay = jitter = drop = 0.0
        bw = 0
        for key in (0, sender, node):
            sh = self.shape.get(key)
            if not sh:
                continue
            delay, jitter, drop = max(delay, sh["delay"]), max(jitter, sh["jitter"]), max(drop, sh["drop"])
            if sh["bw"]:
                bw = sh["bw"] if bw == 0 else min(bw, sh["bw"])
        return delay, jitter, drop, bw

    def _pipe(self, a, b, sender=0, node=0):
        try:
            while True:
                data = a.recv(65536)
                if not data:
                    break
                if sender != 0:
                    delay, jitter, drop, bw = self.shaping(sender, node)
                    if drop and self.rng.random() < drop:
                        break  # the connection reset mid-stream, as a flaky network does
                    wait = delay + (self.rng.random() * jitter if jitter else 0) + (len(data) / bw if bw else 0)
                    if wait:
                        time.sleep(wait)
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


class RemoteProc:
    """A node on another machine (ADR-0069 §2), started over SSH: what the harness asks of a local process."""

    def __init__(self, host, pid):
        self.host = host
        self.pid = pid
        self.dead = False
        self.checked = 0.0

    def ssh(self, command):
        return subprocess.run(["ssh", "-o", "BatchMode=yes", self.host, command], capture_output=True, text=True,
                              timeout=30)

    def poll(self):
        if self.dead:
            return 1
        if time.time() - self.checked < 1.0:
            return None
        self.checked = time.time()
        if self.ssh(f"kill -0 {self.pid}").returncode != 0:
            self.dead = True
            return 1
        return None

    def send_signal(self, sig):
        # By name: the numbers differ between macOS and Linux (SIGSTOP is 17 on one, 19 on the other).
        self.ssh(f"kill -{signal.Signals(sig).name[3:]} {self.pid}")

    def kill(self):
        self.ssh(f"kill -9 {self.pid}")
        self.dead = True

    def wait(self):
        return 0


class Cluster:
    def __init__(self, binary, work, nodes, base, standby=(), racks=0, hosts=None):
        # Where each node runs (ADR-0069 §2): None on this machine, or (user@host, binary there).
        self.hosts = hosts or [None] * nodes
        self.tunnels = []
        self.standby = set(standby)
        # With racks, node i is in rack (i - 1) % racks: nodes 1 to `racks` in different ones (group 0's three).
        self.racks = racks
        self.extra = []  # more options for every node
        # How an empty directory starts (ADR-0066): --init at the cluster's formation, --join after a disk is lost.
        # Ignored once a node's directory has its marker.
        self.start_mode = {}
        self.skew = {}
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
        # The secret file by a relative name: the cluster file must be the same on every machine (its digest signs every
        # request between nodes), and every node runs in its own work directory.
        lines = ["cluster 0dd0ee0ff0aa0bb0", "shards 2", "replicas 3", "secret-file cluster.key"]
        domains = "abcdefgh"
        for i in range(1, nodes + 1):
            domain = domains[(i - 1) % racks] if racks else domains[i - 1]
            lines.append(f"node {i} peer=127.0.0.1:{self.proxy_port(i)} domain={domain}"
                         + (" standby" if i in self.standby else ""))
        with open(self.conf, "w") as f:
            f.write("\n".join(lines) + "\n")

    def rack_of(self, i):
        return (i - 1) % self.racks if self.racks else i - 1

    def rack(self, r):
        return [i for i in range(1, self.n + 1) if self.rack_of(i) == r]

    def proxy_port(self, i):
        return self.base + i

    def s3_port(self, i):
        return self.base + 20 + i

    def peer_port(self, i):
        return self.base + 40 + i

    def remote_work(self, i):
        host, binary = self.hosts[i - 1]
        return os.path.join(os.path.dirname(binary), "run-" + os.path.basename(self.work))

    def node_args(self, i, binary, work):
        return ([binary, "node", os.path.join(work, f"d{i}"), "--cluster-file", os.path.join(work, "cluster.conf"),
                 "--node", str(i), self.start_mode.get(i, "--init"), "--listen", str(self.s3_port(i)),
                 "--credentials", os.path.join(work, "credentials"), "--peer-listen", str(self.peer_port(i))]
                + (["--clock-skew-ms", str(self.skew[i])] if self.skew.get(i) else []) + self.extra)

    def setup_remote(self):
        """Each remote node's directory, files and tunnel: its peer and S3 ports to this machine (`-L`), every node's
        proxy port to it (`-R`). Nothing listens on any host's network."""
        for i in range(1, self.n + 1):
            if self.hosts[i - 1] is None:
                continue
            host, binary = self.hosts[i - 1]
            w = self.remote_work(i)
            subprocess.run(["ssh", "-o", "BatchMode=yes", host, f"mkdir -p {w}"], check=True, timeout=30)
            subprocess.run(["scp", "-q", self.conf, os.path.join(self.work, "cluster.key"),
                            os.path.join(self.work, "credentials"), f"{host}:{w}/"], check=True, timeout=60)
            forwards = []
            for j in range(1, self.n + 1):
                forwards += ["-R", f"{self.proxy_port(j)}:127.0.0.1:{self.proxy_port(j)}"]
            forwards += ["-L", f"{self.peer_port(i)}:127.0.0.1:{self.peer_port(i)}",
                         "-L", f"{self.s3_port(i)}:127.0.0.1:{self.s3_port(i)}"]
            self.tunnels.append(subprocess.Popen(
                ["ssh", "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=5"]
                + forwards + [host], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        time.sleep(2 if self.tunnels else 0)

    def finish_remote(self, keep):
        """The remote nodes' logs into this run's work directory; their directories removed unless kept."""
        for i in range(1, self.n + 1):
            if self.hosts[i - 1] is None:
                continue
            host, _ = self.hosts[i - 1]
            w = self.remote_work(i)
            r = subprocess.run(["ssh", "-o", "BatchMode=yes", host, f"cat {w}/log{i}"], capture_output=True,
                               timeout=60)
            with open(os.path.join(self.work, f"log{i}"), "ab") as f:
                f.write(r.stdout)
            if not keep:
                subprocess.run(["ssh", "-o", "BatchMode=yes", host, f"rm -rf {w}"], timeout=60)
        for t in self.tunnels:
            t.kill()

    def start(self, i):
        if self.hosts[i - 1] is not None:
            host, binary = self.hosts[i - 1]
            w = self.remote_work(i)
            command = " ".join(self.node_args(i, binary, w))
            r = subprocess.run(["ssh", "-o", "BatchMode=yes", host,
                                f"cd {w} && mkdir -p d{i} && (nohup nice -n 10 {command} >> {w}/log{i} 2>&1 < /dev/null & echo $!)"],
                               capture_output=True, text=True, timeout=30)
            self.procs[i] = RemoteProc(host, int(r.stdout.strip() or "0"))
            self.paused.discard(i)
            return
        d = os.path.join(self.work, f"d{i}")
        os.makedirs(d, exist_ok=True)
        log = open(os.path.join(self.work, f"log{i}"), "ab")
        self.procs[i] = subprocess.Popen(self.node_args(i, self.binary, self.work), stdout=log, stderr=log,
                                         cwd=self.work)
        log.close()  # the child has its own; ours would leak a descriptor a start
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
                                  capture_output=True, text=True, timeout=5, cwd=self.work).stdout
        except subprocess.TimeoutExpired:
            return "(no answer in 5 s)\n"

    def status(self, i):
        """[(shard, role, term, leader, last, commit, applied)] as node i reports them, or []."""
        try:
            out = subprocess.run([self.binary, "cluster-status", "--cluster-file", self.conf, "--node", str(i)],
                                 capture_output=True, text=True, timeout=5, cwd=self.work).stdout
        except subprocess.TimeoutExpired:
            return []
        rows = []
        for line in out.splitlines()[1:]:
            f = line.split()
            if len(f) >= 7 and f[0].isdigit():
                rows.append(f)
        return rows

    def operator(self, command, i):
        """`cluster-join` or `cluster-leave` of node i: (whether it answered 0, what it said on stderr)."""
        try:
            r = subprocess.run([self.binary, command, "--cluster-file", self.conf, "--node", str(i)],
                               capture_output=True, text=True, timeout=60, cwd=self.work)
            return r.returncode == 0, r.stderr.strip()
        except subprocess.TimeoutExpired:
            return False, "no answer in 60 s"

    def holders_of(self, i):
        """How many groups still hold node i: shards with it among their voters or learners, and group 0 with it among
        its voters (a learner of group 0 is every node that does not vote in it, ADR-0067). Each judged by the view of
        its highest term, a leader's first: a replica a group removed goes on showing the group it was removed from
        (ADR-0066 §2)."""
        best = {}
        for j in range(1, self.n + 1):
            if j == i or j in self.paused or self.procs.get(j) is None or self.procs[j].poll() is not None:
                continue
            for r in self.status(j):
                if len(r) < 9:
                    continue
                rank = (int(r[2]), r[1] == "leader")
                if r[0] not in best or rank > best[r[0]][0]:
                    best[r[0]] = (rank, r)
        return sum(1 for s, (_, r) in best.items()
                   if (s != "65535" and (str(i) in r[7].split(",") or str(i) in r[8].split(",")))
                   or (s == "65535" and str(i) in r[7].split(",")))

    def wipe(self, i):
        if self.hosts[i - 1] is not None:
            host, _ = self.hosts[i - 1]
            subprocess.run(["ssh", "-o", "BatchMode=yes", host, f"rm -rf {self.remote_work(i)}/d{i}"], timeout=60)
        else:
            shutil.rmtree(os.path.join(self.work, f"d{i}"), ignore_errors=True)
        self.start_mode[i] = "--join"

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


def client(cid, cluster, history, keys, rng, stop, counts, large=0.1, cold=()):
    seq = 0
    while not stop.is_set():
        node = rng.randint(1, cluster.n)
        port = cluster.s3_port(node)
        key = rng.choice(list(keys) + list(cold))
        # A cold key is only read: written once at the start, so that its extent is coded and its reads decode.
        roll = 0.6 if key in cold else rng.random()
        start = history.now()
        if roll < 0.40:
            seq += 1
            tag = f"c{cid}-{seq}"
            body = (tag + "\n").encode()
            if rng.random() < large:
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


NEMESES = ["kill", "pause", "isolate", "isolate-leader", "split", "bridge", "skew", "lose-disk", "rack-kill",
           "rack-isolate", "slow", "flaky", "throttle"]
# The default: every fault but the two that need a mode of their own (`--disk-loss`) or that only cut a node off.
DEFAULT_NEMESES = ["kill", "pause", "isolate", "isolate-leader", "split", "bridge", "skew", "slow", "flaky", "throttle"]


def lose_disk(cluster, victim, stop, log, history):
    """A disk lost, the way the runbook says to recover (ADR-0062, ADR-0065 §7): the node killed, taken out of every
    shard by `cluster-leave`, its directory wiped, started again empty and joined again."""
    held = cluster.holders_of(victim)
    log.append(f"{history.now():8.3f}   node {victim} held replicas of {held} shards")
    cluster.kill(victim)
    answered, said = cluster.operator("cluster-leave", victim)
    if not answered:
        log.append(f"{history.now():8.3f}   cluster-leave {victim} did not answer: {said}")
    # A loss begun is seen through, even if the run's time is up meanwhile: a node left half out is the harness's
    # doing, not the cluster's.
    deadline = time.time() + 90
    while time.time() < deadline and cluster.holders_of(victim) > 0:
        time.sleep(0.5)
    left = cluster.holders_of(victim) == 0
    log.append(f"{history.now():8.3f}   node {victim} {'out of every shard' if left else 'STILL in a shard'}")
    if not left:
        cluster.start(victim)  # its disk kept: it is still a member
        return False
    cluster.wipe(victim)
    cluster.start(victim)
    time.sleep(2)
    if cluster.procs[victim].poll() is not None:
        # Refused (ADR-0066): what it said is the last line of its log.
        with open(os.path.join(cluster.work, f"log{victim}"), errors="replace") as f:
            last = (f.read().strip().splitlines() or [""])[-1]
        log.append(f"{history.now():8.3f}   node {victim} did not start with --join: {last}")
        return False
    answered, said = cluster.operator("cluster-join", victim)
    if not answered:
        log.append(f"{history.now():8.3f}   cluster-join {victim} did not answer: {said}")
        return False
    log.append(f"{history.now():8.3f}   node {victim} wiped, started again and joined")
    # Shards back on it before anything else happens, so that the next loss loses something.
    deadline = time.time() + 90
    while time.time() < deadline and cluster.holders_of(victim) == 0:
        time.sleep(0.5)
    log.append(f"{history.now():8.3f}   node {victim} holds replicas of {cluster.holders_of(victim)} shards again")
    return cluster.holders_of(victim) > 0


def nemesis(cluster, proxy, rng, stop, log, history, kinds, failures):
    """The faults, one at a time; a crash of the harness's own is a failure of the run, not a quiet end of faults."""
    try:
        faults(cluster, proxy, rng, stop, log, history, kinds, failures)
    except Exception as e:  # noqa: BLE001 - any failure here must fail the run
        failures.append(f"the fault thread crashed: {e!r}")
        proxy.partition(set())


def faults(cluster, proxy, rng, stop, log, history, kinds, failures):
    others = lambda i: [j for j in range(1, cluster.n + 1) if j != i]
    while not stop.is_set():
        if stop.wait(rng.uniform(1.0, 3.0)):
            break
        kind = rng.choice(kinds)
        victim = rng.randint(1, cluster.n)
        if kind == "lose-disk":
            # Any node: group 0 moves off a node that leaves (ADR-0067).
            spare = list(range(1, cluster.n + 1))
            if not spare:
                continue
            victim = rng.choice(spare)
            log.append(f"{history.now():8.3f} lose the disk of node {victim}")
            if not lose_disk(cluster, victim, stop, log, history):
                failures.append(f"node {victim}'s disk loss could not be recovered from")
            log.append(f"{history.now():8.3f} healed")
            continue
        if kind == "isolate-leader":
            leaders = {s: l for s, l in cluster.leaders().items() if s != 65535 and l != 0}
            if leaders:
                victim = rng.choice(sorted(leaders.values()))
            kind = "isolate"
        hold = rng.uniform(2.0, 6.0)
        t = history.now()
        if kind in ("slow", "flaky", "throttle"):
            # The network misbehaving without parting (ADR-0069 §1): every link slow and jittery, every link
            # resetting connections now and then, or one node's links throttled.
            if kind == "slow":
                delay, jitter = rng.uniform(0.02, 0.2), rng.uniform(0, 0.1)
                proxy.shape[0] = dict(delay=delay, jitter=jitter, drop=0.0, bw=0)
                log.append(f"{t:8.3f} slow every link: {delay * 1000:.0f} ms, jitter {jitter * 1000:.0f} ms")
            elif kind == "flaky":
                drop = rng.uniform(0.01, 0.05)
                proxy.shape[0] = dict(delay=0.0, jitter=0.0, drop=drop, bw=0)
                log.append(f"{t:8.3f} flaky links: {drop * 100:.1f}% of chunks reset their connection")
            else:
                bw = rng.randint(50_000, 200_000)
                proxy.shape[victim] = dict(delay=0.0, jitter=0.0, drop=0.0, bw=bw)
                log.append(f"{t:8.3f} throttle node {victim}'s links to {bw // 1000} KB/s")
            stop.wait(hold)
            proxy.shape.clear()
        elif kind in ("rack-kill", "rack-isolate"):
            # A rack (a failure domain, ADR-0059 §2) at once: its nodes killed, or cut off from the other racks while
            # they still see each other. Each shard has one replica a rack, so the others keep a majority.
            r = rng.randrange(cluster.racks or cluster.n)
            members = cluster.rack(r)
            if kind == "rack-kill":
                log.append(f"{t:8.3f} kill rack {r} (nodes {members})")
                for i in members:
                    cluster.kill(i)
                stop.wait(hold)
                for i in members:
                    cluster.start(i)
            else:
                log.append(f"{t:8.3f} isolate rack {r} (nodes {members})")
                proxy.partition({frozenset((a, b)) for a in members for b in range(1, cluster.n + 1)
                                 if b not in members})
                stop.wait(hold)
                proxy.partition(set())
        elif kind == "kill":
            log.append(f"{t:8.3f} kill node {victim}")
            cluster.kill(victim)
            stop.wait(hold)
            cluster.start(victim)
        elif kind == "skew":
            # Restarted with its peer clock off: within the signatures' 60 s, it should not matter; past it, the
            # node is cut off as by a partition, its requests refused (ADR-0059 §4).
            skew = rng.choice([-1, 1]) * rng.randint(20_000, 100_000)
            log.append(f"{t:8.3f} skew node {victim}'s clock by {skew / 1000:+.0f} s")
            cluster.kill(victim)
            cluster.skew[victim] = skew
            cluster.start(victim)
            stop.wait(hold)
            cluster.kill(victim)
            cluster.skew.pop(victim, None)
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


def lists_of(events, keys):
    """The listings, as operations of the check across keys: the set of key indexes each saw."""
    out = []
    index = {k: i for i, k in enumerate(keys)}
    for e in events:
        if e["op"] != "list" or e["outcome"] == "fail":
            continue
        end = e["end"] if e["outcome"] == "ok" else INF
        seen = frozenset(index[k] for k in e["value"] if k in index)
        out.append(Op("L", seen, e["start"], end, e["c"], f"list@n{e['n']}"))
    return out


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
    if args.disk_loss:
        args.nodes = max(args.nodes, 4)
    if args.racks:
        args.nodes = max(args.nodes, 2 * args.racks)
    print(f"chaos: seed {seed}, {args.nodes} nodes, {args.seconds} s, work {work}")
    rng = random.Random(seed)
    if args.nemesis is None:
        args.nemesis = ",".join(DEFAULT_NEMESES + (["lose-disk"] if args.disk_loss else [])
                                + (["rack-kill", "rack-isolate"] if args.racks else []))
    for k in args.nemesis.split(","):
        if k not in NEMESES:
            print(f"chaos: no fault called {k}; there are {', '.join(NEMESES)}")
            return False
    nodes = max(args.nodes, 4) if args.disk_loss else args.nodes
    args.nodes = nodes
    standby = list(range(4, nodes + 1)) if args.disk_loss else []
    if args.racks and args.disk_loss:
        print("chaos: --racks and --disk-loss are runs of their own")
        return False
    hosts = None
    if args.hosts:
        # local, or user@host:/path/to/cosmostore there (ADR-0069 §2).
        hosts = []
        for h in args.hosts.split(","):
            if h == "local":
                hosts.append(None)
            else:
                host, _, path = h.partition(":")
                hosts.append((host, path))
        if len(hosts) != nodes:
            print(f"chaos: --hosts names {len(hosts)} machines for {nodes} nodes")
            return False
    cluster = Cluster(binary, work, nodes, args.port_base, standby, args.racks, hosts)
    if args.code_after_seconds:
        # Large values coded within seconds (ADR-0064): reads of them decode, under the faults.
        cluster.extra += ["--code-after-seconds", str(args.code_after_seconds)]
    proxy = Proxy({i: (cluster.proxy_port(i), cluster.peer_port(i)) for i in range(1, args.nodes + 1)})
    proxy.start()
    ok = False
    try:
        cluster.setup_remote()
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
        # The standbys joined before the clients start, so that there are nodes outside group 0 to lose disks of.
        for i in standby:
            answered, said = cluster.operator("cluster-join", i)
            if not answered:
                print(f"FAIL node {i} could not join: {said}")
                return False
            deadline = time.time() + 60
            while time.time() < deadline and cluster.holders_of(i) == 0:
                time.sleep(0.5)
        keys = [f"k{i}" for i in range(args.keys)]
        history = History()
        cold = []
        if args.code_after_seconds:
            for c in range(2):
                key = f"kcold{c}"
                tag = f"cold-{c}"
                start = history.now()
                status, _ = s3(cluster.s3_port(1), "PUT", f"/{BUCKET}/{key}",
                               body=(tag + "\n").encode() + os.urandom(1_000_000), timeout=30)
                if status != 200:
                    print(f"FAIL the cold key {key} could not be written: {status}")
                    return False
                history.add(dict(c=-2, n=1, op="put", key=key, value=tag, start=start, end=history.now(),
                                 outcome="ok", status=status))
                cold.append(key)
        counts = {}
        failures = []
        stop = threading.Event()
        log = []
        threads = [threading.Thread(target=client,
                                    args=(c, cluster, history, keys, random.Random(seed * 31 + c), stop, counts,
                                          0.5 if args.code_after_seconds else 0.1, cold))
                   for c in range(args.clients)]
        threads.append(threading.Thread(target=nemesis, args=(cluster, proxy, rng, stop, log, history, args.nemesis.split(","), failures)))
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
        keys = keys + cold
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
                                if p and not isinstance(p, RemoteProc) and p.poll() is None:
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
        for f in failures:
            print(f"FAIL {f}")
            ok = False
        if unanswered:
            print("FAIL after the heal, no answer for: " + ", ".join(unanswered))
            ok = False
        # A replica that stopped itself (a journal it found corrupt, a failed write) is a failure of its own. The
        # remote nodes' logs first (ADR-0069 §2).
        cluster.stop_all()
        cluster.finish_remote(keep=True)
        for i in range(1, args.nodes + 1):
            with open(os.path.join(work, f"log{i}"), errors="replace") as f:
                for line in f:
                    if "stopped" in line or "panic" in line:
                        print(f"FAIL node {i}: {line.strip()}")
                        ok = False
        per = ops_by_key(history.events, keys)
        lists = lists_of(history.events, keys)
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
        # Every key together: a listing is one moment (the exit review's gap); after the per-key checks, which name a
        # bad operation more plainly.
        if ok:
            t = time.time()
            good, at = linearizable_all(per, lists, keys)
            took = time.time() - t
            if good:
                print(f"ok   every key together: {len(lists)} listings, each one moment ({took:.1f} s)")
            else:
                ok = False
                print(f"FAIL every key together: no order puts {at!r} ({at if good is None else 'a listing of no one moment'})")
        return ok
    finally:
        proxy.stop()
        cluster.stop_all()
        if cluster.tunnels:
            for i in range(1, cluster.n + 1):
                if cluster.hosts[i - 1] is not None and (ok and not args.keep):
                    host, _ = cluster.hosts[i - 1]
                    subprocess.run(["ssh", "-o", "BatchMode=yes", host, f"rm -rf {cluster.remote_work(i)}"],
                                   timeout=60)
            for t in cluster.tunnels:
                t.kill()
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
    p.add_argument("--nemesis", default=None, help="the faults to choose from, by name, with commas")
    p.add_argument("--hosts", default=None,
                   help="where each node runs, with commas: local, or user@host:/path/to/cosmostore (ADR-0069)")
    p.add_argument("--code-after-seconds", type=int, default=0,
                   help="passed to the nodes: the large values' extents are coded this soon (ADR-0064)")
    p.add_argument("--racks", type=int, default=0,
                   help="nodes in this many racks (at least two nodes each), and rack-kill and rack-isolate among the faults")
    p.add_argument("--disk-loss", action="store_true",
                   help="four nodes or more, the fourth on joined from standby, and lose-disk among the faults")
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args()
    if args.self_test:
        sys.exit(0 if self_test() else 1)
    sys.exit(0 if run(args) else 1)


if __name__ == "__main__":
    main()
