# SPDX-License-Identifier: Apache-2.0
"""Make tampered.wasm from hello-counter.wasm by changing exactly one byte.

The changed byte is inside the UI title text ("Claw Applet" -> "Claw Applat"),
so the module stays a valid WebAssembly file. Only its SHA-256 differs.
Use it to test that a host rejects a module whose digest does not match.

    python3 make_tampered.py ../hello-counter/hello-counter.wasm tampered.wasm
"""
import hashlib
import sys

src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, "rb").read())
needle = b"Hello, Claw Applet"
i = data.find(needle)
if i < 0 or data.count(needle) != 1:
    sys.exit("title text not found exactly once")
pos = i + len(needle) - 2          # the 'e' in "Applet"
assert data[pos:pos + 1] == b"e"
data[pos] = ord("a")
open(dst, "wb").write(data)
print(f"changed offset {pos}: 0x65 -> 0x61")
print(hashlib.sha256(open(src, "rb").read()).hexdigest(), src)
print(hashlib.sha256(data).hexdigest(), dst)
