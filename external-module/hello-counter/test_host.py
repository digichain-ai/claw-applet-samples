# SPDX-License-Identifier: Apache-2.0
"""Minimal host stub for hello-counter.wasm (uses the `wasmtime` Python package).

Runs: init -> KV miss -> +1 -> +1 -> suspend -> reset -> +1 -> shutdown,
then a second instance that restores count from KV, then a third instance
that resumes from the snapshot. Exits non-zero on the first mismatch.

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

    def action(self, name):
        ev = {"action": {"context": "{}", "name": name, "surfaceId": "main"}}
        assert self.send({"kind": "event", "event": ev}) == {"ok": True}
        self.drain()


def last_count(host):
    vals = [e["updateDataModel"]["value"] for e in host.published if "updateDataModel" in e]
    return vals[-1] if vals else None


def check(label, got, want):
    print(f"{'PASS' if got == want else 'FAIL'} {label}: {got!r}")
    if got != want:
        sys.exit(1)


def main(path):
    kv = {}
    h1 = Host(kv)
    a = Instance(path, h1)
    check("init reply", a.send({"kind": "init", "context": {}}), {"ok": True})
    a.drain()
    check("surface created", h1.published[0], {"version": "v0.9", "createSurface": {"surfaceId": "main", "catalogId": "desktop-ai:v1"}})
    check("components root", h1.published[1]["updateComponents"]["components"][0]["id"], "root")
    check("count after init (KV miss)", last_count(h1), 0)
    a.action("applet.increment")
    a.action("applet.increment")
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

    h2 = Host(kv)
    b = Instance(path, h2)
    b.send({"kind": "init", "context": {}})
    b.drain()
    check("second instance restores from KV", last_count(h2), 1)

    h3 = Host({})
    c = Instance(path, h3)
    check("resume reply", c.send({"kind": "resume", "context": {}, "snapshot": snap["snapshot"]}), {"ok": True})
    c.drain()
    check("resume restores snapshot (KV empty)", last_count(h3), 2)

    for i in range(1000):
        c.action("applet.increment")
    check("1000 more increments", last_count(h3), 1002)
    print("ALL PASS")


if __name__ == "__main__":
    main(sys.argv[1])
