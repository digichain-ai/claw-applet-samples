#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Rebuild both wasm files from source and print their SHA-256.
# Needs: wat2wasm and wasm-validate from WABT 1.0.36, python3.
set -eu
cd "$(dirname "$0")"
wat2wasm external-module/hello-counter/hello-counter.wat -o external-module/hello-counter/hello-counter.wasm
wasm-validate --disable-bulk-memory --disable-reference-types --disable-multi-value \
  --disable-sign-ext --disable-saturating-float-to-int --disable-simd \
  external-module/hello-counter/hello-counter.wasm
python3 external-module/tampered/make_tampered.py \
  external-module/hello-counter/hello-counter.wasm external-module/tampered/tampered.wasm
sha256sum external-module/hello-counter/hello-counter.wasm external-module/tampered/tampered.wasm
