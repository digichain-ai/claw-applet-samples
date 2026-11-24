#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Rebuild the wasm files that have source here and print their SHA-256.
# external-module/travel-album/travel-album.wasm has no source here; it is only checked.
# Needs: wat2wasm and wasm-validate from WABT 1.0.36, python3.
set -eu
cd "$(dirname "$0")"
wat2wasm external-module/hello-counter/hello-counter.wat -o external-module/hello-counter/hello-counter.wasm
wasm-validate --disable-bulk-memory --disable-reference-types --disable-multi-value \
  --disable-sign-ext --disable-saturating-float-to-int --disable-simd \
  external-module/hello-counter/hello-counter.wasm
python3 external-module/tampered/make_tampered.py \
  external-module/hello-counter/hello-counter.wasm external-module/tampered/tampered.wasm
wat2wasm external-module/import-wasi/import-wasi.wat -o external-module/import-wasi/import-wasi.wasm
wasm-validate external-module/import-wasi/import-wasi.wasm
sha256sum external-module/hello-counter/hello-counter.wasm external-module/tampered/tampered.wasm \
  external-module/import-wasi/import-wasi.wasm external-module/travel-album/travel-album.wasm
