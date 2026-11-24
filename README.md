# claw-applet-samples

Small, self-contained samples for **Claw Applets**: mini-apps that a chat app
can send and open on a phone, a desktop or a TV. An applet has a declarative
UI (one variant per device type) and, optionally, a WebAssembly logic module.

Everything here except `external-module/travel-album/` was written only to serve as a
sample and is not product code. `travel-album.wasm` is a compiled module published as a
realistic test input; its source is not part of this repository.

| Path | What it is |
|---|---|
| `external-module/hello-counter/` | A minimal logic module, written by hand in WebAssembly text (`.wat`). Tap **+1** to count, **Reset** to clear; the count is kept in key-value storage. No SDK, no WASI, MVP instructions only. |
| `external-module/hello-counter-0.2.1/` | hello-counter **0.2.1**: same counter, but it takes the `surfaceId` from the context the host passes at init / resume and draws only on that surface. A host that enforces "an instance draws only on its own surface" rejects 0.1.0's hard-coded `"main"`. Without a usable `surfaceId` 0.2.1 replies `{"err":"no surfaceId"}` and publishes nothing. 0.1.0 above is kept byte-for-byte, because published packages pin its digest. |
| `external-module/tampered/` | `hello-counter.wasm` with **one byte changed on purpose**. Use it to test that a host rejects a module whose SHA-256 does not match. Do not use it as a real module. |
| `external-module/import-wasi/` | A module that **breaks the import rule on purpose**: it imports WASI `proc_exit` instead of `claw.claw_host_call`. A platform must reject it at admission. Use it only as a negative test. |
| `external-module/travel-album/` | The logic module of an interactive travel album, **compiled only**: the `.wasm` and a description, no source. In this build **Next** moves two pages. See its `README.md`. |
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

It rebuilds the four `.wasm` files that have source here (hello-counter 0.1.0 and 0.2.1, tampered,
import-wasi), and prints their SHA-256 together with that of `travel-album.wasm`,
which is checked but not rebuilt. The output must match `SHA256SUMS`:

```sh
sha256sum -c SHA256SUMS
```

To run the hello-counter behaviour test (needs `pip install wasmtime==27.0.2`):

```sh
python3 external-module/hello-counter/test_host.py external-module/hello-counter/hello-counter.wasm
python3 external-module/hello-counter-0.2.1/test_host.py external-module/hello-counter-0.2.1/hello-counter.wasm
```

## Using a module by URL

A platform that admits external modules takes a fixed URL and a digest, for example:

- release asset: `https://github.com/<org>/claw-applet-samples/releases/download/v0.2.0/hello-counter.wasm`
- raw file at a commit: `https://raw.githubusercontent.com/<org>/claw-applet-samples/<40-hex-commit>/external-module/hello-counter/hello-counter.wasm`

Modules here are **not signed**. A platform checks and signs its own manifest after admission.

## License

Apache License 2.0; see `LICENSE`. Source files carry an
`SPDX-License-Identifier: Apache-2.0` line. JSON files cannot hold comments and
are covered by `LICENSE`; `applet.json` also states `"license": "Apache-2.0"`.
