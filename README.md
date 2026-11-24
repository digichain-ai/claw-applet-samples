# claw-applet-samples

Small, self-contained samples for **Claw Applets**: mini-apps that a chat app
can send and open on a phone, a desktop or a TV. An applet has a declarative
UI (one variant per device type) and, optionally, a WebAssembly logic module.

Everything here was written only to serve as a sample. None of it is product code.

| Path | What it is |
|---|---|
| `external-module/hello-counter/` | A minimal logic module, written by hand in WebAssembly text (`.wat`). Tap **+1** to count, **Reset** to clear; the count is kept in key-value storage. No SDK, no WASI, MVP instructions only. |
| `external-module/tampered/` | `hello-counter.wasm` with **one byte changed on purpose**. Use it to test that a host rejects a module whose SHA-256 does not match. Do not use it as a real module. |
| `declarative/hello-card/` | A minimal declarative applet: one greeting card with a phone and a desktop variant. The example data is made up. |

## Logic module interface (claw-applet/1)

```
import  claw.claw_host_call(ptr: i32, len: i32) -> i64     ; JSON request, returns a request id
export  memory
export  claw_alloc(len: i32) -> i32
export  claw_free(ptr: i32, len: i32)
export  claw_on_event(ptr: i32, len: i32) -> i64          ; (replyPtr << 32) | replyLen, 0 = no reply
```

The host sends JSON messages: `{"kind":"init"}`, `{"kind":"event","event":{...}}`,
`{"kind":"suspend"}`, `{"kind":"resume","snapshot":"..."}`, `{"kind":"shutdown"}`.
The module calls the host with JSON requests such as `ui.publish`, `storage.get`
and `storage.set`. See the comments at the top of `hello-counter.wat`.

## Build and check

Tools: WABT 1.0.36 (`wat2wasm`, `wasm-validate`) and Python 3.

```sh
./build.sh
```

It rebuilds both `.wasm` files and prints their SHA-256. The output must match
`SHA256SUMS`:

```sh
sha256sum -c SHA256SUMS
```

To run the hello-counter behaviour test (needs `pip install wasmtime==27.0.2`):

```sh
python3 external-module/hello-counter/test_host.py external-module/hello-counter/hello-counter.wasm
```

## Using a module by URL

A platform that admits external modules takes a fixed URL and a digest, for example:

- release asset: `https://github.com/<org>/claw-applet-samples/releases/download/v0.1.0/hello-counter.wasm`
- raw file at a commit: `https://raw.githubusercontent.com/<org>/claw-applet-samples/<40-hex-commit>/external-module/hello-counter/hello-counter.wasm`

Modules here are **not signed**. A platform checks and signs its own manifest after admission.

## License

Apache License 2.0; see `LICENSE`. Source files carry an
`SPDX-License-Identifier: Apache-2.0` line. JSON files cannot hold comments and
are covered by `LICENSE`; `applet.json` also states `"license": "Apache-2.0"`.
