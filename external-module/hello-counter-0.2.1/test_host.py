# SPDX-License-Identifier: Apache-2.0
"""Minimal host stub for hello-counter 0.2.1 (hello-counter.wasm in this directory) (uses the `wasmtime` Python package).

Runs: init -> KV miss -> +1 -> +1 -> suspend -> reset -> +1 -> shutdown,
then a second instance that restores count from KV, then a third instance
that resumes from the snapshot. Every instance gets its own surfaceId in the
context, and every ui.publish must use exactly that surface (all three
envelopes: createSurface, updateComponents, updateDataModel). A context with
no usable surfaceId must get {"err":"no surfaceId"} and no host call at all.
Exits non-zero on the first mismatch.

    pip install wasmtime==<pinned in README>
    python3 test_host.py hello-counter.wasm
"""
import json
import sys

import wasmtime


class Host:
    def __init__(self, kv):
        self.kv = kv          # key -> hex string (shared across instances)
        self.next_id = 0
        self.calls = []
        self.published = []
        self.pending = []     # host results to deliver as events

    def call(self, body):
        req = json.loads(body)
        self.calls.append(req)
        self.next_id += 1
        rid = self.next_id
        op = req["op"]
        if op == "ui.publish":
            self.published.append(json.loads(req["envelope"]))
            self.pending.append({"hostResult": {"id": rid, "ok": None}})
        elif op == "storage.set":
            self.kv[req["key"]] = req["value"]
            self.pending.append({"hostResult": {"id": rid, "ok": None}})
        elif op == "storage.get":
            if req["key"] in self.kv:
                self.pending.append({"hostResult": {"id": rid, "ok": {"value": self.kv[req["key"]]}}})
            else:
                self.pending.append({"hostResult": {"err": "notFound", "id": rid}})
        else:
            return -1
        return rid


class Instance:
    def __init__(self, path, host):
        engine = wasmtime.Engine()
        self.store = wasmtime.Store(engine)
        module = wasmtime.Module.from_file(engine, path)
        self.host = host

        def host_call(caller, ptr, ln):
            mem = caller["memory"]
            body = bytes(mem.read(caller, ptr, ptr + ln))
            return host.call(body)

        ty = wasmtime.FuncType([wasmtime.ValType.i32(), wasmtime.ValType.i32()], [wasmtime.ValType.i64()])
        linker = wasmtime.Linker(engine)
        linker.define_func("claw", "claw_host_call", ty, host_call, access_caller=True)
        inst = linker.instantiate(self.store, module)
        ex = inst.exports(self.store)
        self.mem, self.alloc, self.on_event = ex["memory"], ex["claw_alloc"], ex["claw_on_event"]

    def send(self, msg):
        data = json.dumps(msg, separators=(",", ":"), sort_keys=True).encode()
        ptr = self.alloc(self.store, len(data))
        assert ptr != 0, "claw_alloc failed"
        self.mem.write(self.store, data, ptr)
        r = self.on_event(self.store, ptr, len(data)) & 0xFFFFFFFFFFFFFFFF
        rp, rl = r >> 32, r & 0xFFFFFFFF
        return json.loads(bytes(self.mem.read(self.store, rp, rp + rl))) if r else None

    def drain(self):
        while self.host.pending:
            ev = self.host.pending.pop(0)
            assert self.send({"kind": "event", "event": ev}) == {"ok": True}

    def action(self, name, sid="main"):
        ev = {"action": {"context": "{}", "name": name, "surfaceId": sid}}
        assert self.send({"kind": "event", "event": ev}) == {"ok": True}
        self.drain()


def last_count(host):
    vals = [e["updateDataModel"]["value"] for e in host.published if "updateDataModel" in e]
    return vals[-1] if vals else None


def surfaces(host):
    """surfaceId of every published envelope, in order."""
    return [next(iter(e[k]["surfaceId"] for k in e if k != "version")) for e in host.published]


def check(label, got, want):
    print(f"{'PASS' if got == want else 'FAIL'} {label}: {got!r}")
    if got != want:
        sys.exit(1)


def main(path):
    kv = {}
    h1 = Host(kv)
    a = Instance(path, h1)
    check("init reply", a.send({"kind": "init", "context": {"caps": ["ui", "storage.kv"], "surfaceId": "s-7f3a"}}), {"ok": True})
    a.drain()
    check("surface created", h1.published[0], {"version": "v0.9", "createSurface": {"surfaceId": "s-7f3a", "catalogId": "desktop-ai:v1"}})
    check("components root", h1.published[1]["updateComponents"]["components"][0]["id"], "root")
    check("count after init (KV miss)", last_count(h1), 0)
    a.action("applet.increment", "s-7f3a")
    a.action("applet.increment", "s-7f3a")
    check("count after +1 +1", last_count(h1), 2)
    check("kv after +1 +1", kv.get("count"), "0200000000000000")
    snap = a.send({"kind": "suspend"})
    check("suspend reply", snap, {"snapshot": "0200000000000000"})
    a.action("applet.reset")
    check("count after reset", last_count(h1), 0)
    a.action("applet.increment")
    check("count after reset +1", last_count(h1), 1)
    check("unknown kind", a.send({"kind": "bogus"}), {"err": "bad kind"})
    check("shutdown reply", a.send({"kind": "shutdown"}), {"ok": True})
    check("instance a: every publish on s-7f3a", set(surfaces(h1)), {"s-7f3a"})
    kinds = {next(k for k in e if k != "version") for e in h1.published}
    check("instance a: all three envelope kinds seen", kinds, {"createSurface", "updateComponents", "updateDataModel"})

    h2 = Host(kv)
    b = Instance(path, h2)
    b.send({"kind": "init", "context": {"surfaceId": "s-11aa"}})
    b.drain()
    check("second instance restores from KV", last_count(h2), 1)
    check("second instance on its own surface", set(surfaces(h2)), {"s-11aa"})

    h3 = Host({})
    c = Instance(path, h3)
    check("resume reply", c.send({"kind": "resume", "context": {"surfaceId": "s-9c2e"}, "snapshot": snap["snapshot"]}), {"ok": True})
    c.drain()
    check("resume restores snapshot (KV empty)", last_count(h3), 2)
    check("resume: publishes on the new surface", set(surfaces(h3)), {"s-9c2e"})

    for i in range(1000):
        c.action("applet.increment")
    check("1000 more increments", last_count(h3), 1002)
    check("after 1000 events still on s-9c2e", set(surfaces(h3)), {"s-9c2e"})

    # negative: no usable surfaceId -> error reply, no host call, no UI (init and resume)
    bad = (("missing", {}), ("empty", {"surfaceId": ""}), ("quote", {"surfaceId": 'a"b'}),
           ("space", {"surfaceId": "a b"}), ("65 bytes", {"surfaceId": "x" * 65}), ("not a string", {"surfaceId": 7}))
    for label, ctx in bad:
        for kind in ("init", "resume"):
            h = Host({})
            d = Instance(path, h)
            msg = {"kind": kind, "context": ctx}
            if kind == "resume":
                msg["snapshot"] = snap["snapshot"]
            check("%s surfaceId %s: error reply" % (kind, label), d.send(msg), {"err": "no surfaceId"})
            check("%s surfaceId %s: no host call" % (kind, label), h.calls, [])
    # edge: a 64-byte id and the allowed punctuation are kept as given
    for label, sid in (("64 bytes", "y" * 64), ("allowed punctuation", "s.1_a:b-c")):
        h = Host({})
        d = Instance(path, h)
        check("init surfaceId %s" % label, d.send({"kind": "init", "context": {"surfaceId": sid}}), {"ok": True})
        d.drain()
        check("surfaceId %s used" % label, set(surfaces(h)), {sid})
    print("ALL PASS")


if __name__ == "__main__":
    main(sys.argv[1])
