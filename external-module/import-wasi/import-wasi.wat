;; SPDX-License-Identifier: Apache-2.0
;;
;; import-wasi: a module that breaks the import rule ON PURPOSE.
;;
;; claw-applet/1 allows exactly one import, claw.claw_host_call. This module
;; imports wasi_snapshot_preview1.proc_exit instead, so a platform must reject
;; it at admission (import allowlist) before it is ever instantiated.
;; Use it only as a negative test. Do not use it as a real module.
(module
  (import "wasi_snapshot_preview1" "proc_exit" (func (param i32)))
  (func (export "claw_alloc") (param i32) (result i32) i32.const 4096)
  (func (export "claw_free") (param i32 i32))
  (func (export "claw_on_event") (param i32 i32) (result i32)
    i32.const 0
  )
  (memory (export "memory") 1)
)
