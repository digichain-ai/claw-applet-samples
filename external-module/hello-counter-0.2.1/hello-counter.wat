;; SPDX-License-Identifier: Apache-2.0
;; hello-counter 0.2.1: a minimal Claw Applet logic module, written by hand in
;; WebAssembly text format. It uses no SDK and no WASI. It only needs the
;; claw-applet/1 guest ABI:
;;
;;   import  claw.claw_host_call(ptr i32, len i32) -> i64
;;   export  memory
;;   export  claw_alloc(len i32) -> i32
;;   export  claw_free(ptr i32, len i32)
;;   export  claw_on_event(ptr i32, len i32) -> i64   ;; (replyPtr << 32) | replyLen, 0 = no reply
;;
;; Behaviour
;;   init / resume : read "surfaceId" from the context the host passes (F26
;;                   §6.1: the context carries this instance's surfaceId), create
;;                   that surface, publish a title, the count and two buttons,
;;                   then ask the host for KV key "count". All later UI goes to
;;                   the same surface. A host may only draw an instance on its
;;                   own surface (F26 T6), so the id must not be hard-coded.
;;                   If the context has no usable surfaceId (missing, empty,
;;                   longer than 64 bytes, or a character outside
;;                   A-Z a-z 0-9 . _ : -), init / resume reply
;;                   {"err":"no surfaceId"} and publish no UI.
;;                   (0.1.0, in ../hello-counter/, hard-codes "main"; a host that
;;                   enforces T6 rejects that UI. 0.1.0 is kept unchanged because
;;                   published packages pin its digest.)
;;   action applet.increment : count += 1, save to KV, publish count.
;;   action applet.reset     : count  = 0, save to KV, publish count.
;;   hostResult of the boot storage.get : restore count (8-byte little endian).
;;   suspend  : reply {"snapshot":"<16 hex chars>"}.
;;   shutdown : reply {"ok":true}.
;;
;; Inputs are compact JSON from the host. The module matches fixed
;; substrings instead of running a full JSON parser; this keeps it small and
;; easy to audit. It uses only WebAssembly MVP instructions.
(module
  (import "claw" "claw_host_call" (func $host_call (param i32 i32) (result i64)))

  ;; page 0  : 0x0000-0x0fff constant strings, 0x1000-0xffff input heap
  ;; page 1  : 0x10000-0x17fff host-call bodies, 0x18000-0x18fff replies
  (memory (export "memory") 2 2)

  (global $count   (mut i64) (i64.const 0))
  (global $boot_id (mut i64) (i64.const -1))
  (global $bump    (mut i32) (i32.const 0x1000))
  (global $hex_ok  (mut i32) (i32.const 0))
  (global $sid_len (mut i32) (i32.const 0))

  ;; ---- constant strings: (offset, length) noted on each line ----
  (data (i32.const 0x0000) "\"kind\":\"init\"")                    ;; 13
  (data (i32.const 0x0020) "\"kind\":\"resume\"")                  ;; 15
  (data (i32.const 0x0040) "\"kind\":\"event\"")                   ;; 14
  (data (i32.const 0x0060) "\"kind\":\"shutdown\"")                ;; 17
  (data (i32.const 0x0080) "\"kind\":\"suspend\"")                 ;; 16
  (data (i32.const 0x00a0) "\"action\":")                          ;; 9
  (data (i32.const 0x00c0) "\"name\":\"applet.increment\"")        ;; 25
  (data (i32.const 0x00e0) "\"name\":\"applet.reset\"")            ;; 21
  (data (i32.const 0x0100) "\"hostResult\":")                      ;; 13
  (data (i32.const 0x0120) "\"id\":")                              ;; 5
  (data (i32.const 0x0140) "\"value\":\"")                         ;; 9
  (data (i32.const 0x0160) "\"snapshot\":\"")                      ;; 12
  (data (i32.const 0x0180) "{\"ok\":true}")                        ;; 11
  (data (i32.const 0x01a0) "{\"err\":\"bad kind\"}")               ;; 18
  (data (i32.const 0x01c0) "{\"op\":\"storage.get\",\"key\":\"count\"}")          ;; 34
  (data (i32.const 0x0200) "{\"op\":\"storage.set\",\"key\":\"count\",\"value\":\"") ;; 43
  (data (i32.const 0x0240) "\"}")                                  ;; 2
  (data (i32.const 0x0260) "0123456789abcdef")                     ;; 16
  ;; ui.publish createSurface
  (data (i32.const 0x0300)
    "{\"op\":\"ui.publish\",\"envelope\":\"{\\\"version\\\":\\\"v0.9\\\",\\\"createSurface\\\":{\\\"surfaceId\\\":\\\"\01\\\",\\\"catalogId\\\":\\\"desktop-ai:v1\\\"}}\"}")
  ;; ui.publish updateComponents
  (data (i32.const 0x0400)
    "{\"op\":\"ui.publish\",\"envelope\":\"{\\\"version\\\":\\\"v0.9\\\",\\\"updateComponents\\\":{\\\"surfaceId\\\":\\\"\01\\\",\\\"components\\\":[{\\\"id\\\":\\\"root\\\",\\\"component\\\":\\\"Column\\\",\\\"children\\\":[\\\"title\\\",\\\"count\\\",\\\"inc\\\",\\\"reset\\\"]},{\\\"id\\\":\\\"title\\\",\\\"component\\\":\\\"Text\\\",\\\"text\\\":\\\"Hello, Claw Applet\\\"},{\\\"id\\\":\\\"count\\\",\\\"component\\\":\\\"Text\\\",\\\"text\\\":{\\\"path\\\":\\\"/count\\\"}},{\\\"id\\\":\\\"inc\\\",\\\"component\\\":\\\"Button\\\",\\\"child\\\":\\\"incLabel\\\",\\\"action\\\":{\\\"event\\\":{\\\"name\\\":\\\"applet.increment\\\"}}},{\\\"id\\\":\\\"incLabel\\\",\\\"component\\\":\\\"Text\\\",\\\"text\\\":\\\"+1\\\"},{\\\"id\\\":\\\"reset\\\",\\\"component\\\":\\\"Button\\\",\\\"child\\\":\\\"resetLabel\\\",\\\"action\\\":{\\\"event\\\":{\\\"name\\\":\\\"applet.reset\\\"}}},{\\\"id\\\":\\\"resetLabel\\\",\\\"component\\\":\\\"Text\\\",\\\"text\\\":\\\"Reset\\\"}]}}\"}")
  ;; ui.publish updateDataModel /count: prefix + decimal + suffix
  (data (i32.const 0x0900)
    "{\"op\":\"ui.publish\",\"envelope\":\"{\\\"version\\\":\\\"v0.9\\\",\\\"updateDataModel\\\":{\\\"surfaceId\\\":\\\"\01\\\",\\\"path\\\":\\\"/count\\\",\\\"value\\\":")
  (data (i32.const 0x0a00) "}}\"}")                                ;; 4
  ;; byte 0x01 in the three ui.publish templates above marks where the surfaceId goes
  (data (i32.const 0x0b00) "\"surfaceId\":\"")                    ;; 13
  (data (i32.const 0x0b20) "{\"err\":\"no surfaceId\"}")          ;; 22
  ;; 0x0c00-0x0c3f : the surfaceId in use (length in $sid_len)

  ;; ---- small helpers ----
  (func $strlen (param $p i32) (result i32) (local $n i32)
    (block $done (loop $l
      (br_if $done (i32.eqz (i32.load8_u (i32.add (local.get $p) (local.get $n)))))
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (br $l)))
    (local.get $n))

  (func $copy (param $dst i32) (param $src i32) (param $n i32) (result i32)
    (block $done (loop $l
      (br_if $done (i32.eqz (local.get $n)))
      (i32.store8 (local.get $dst) (i32.load8_u (local.get $src)))
      (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
      (local.set $src (i32.add (local.get $src) (i32.const 1)))
      (local.set $n (i32.sub (local.get $n) (i32.const 1)))
      (br $l)))
    (local.get $dst))

  ;; index of needle in hay, or -1
  (func $find (param $h i32) (param $hn i32) (param $s i32) (param $sn i32) (result i32)
    (local $i i32) (local $j i32)
    (block $none (loop $outer
      (br_if $none (i32.gt_s (i32.add (local.get $i) (local.get $sn)) (local.get $hn)))
      (local.set $j (i32.const 0))
      (block $miss (loop $inner
        (if (i32.eq (local.get $j) (local.get $sn)) (then (return (local.get $i))))
        (br_if $miss (i32.ne
          (i32.load8_u (i32.add (local.get $h) (i32.add (local.get $i) (local.get $j))))
          (i32.load8_u (i32.add (local.get $s) (local.get $j)))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $inner)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $outer)))
    (i32.const -1))

  (func $has (param $h i32) (param $hn i32) (param $s i32) (param $sn i32) (result i32)
    (i32.ge_s (call $find (local.get $h) (local.get $hn) (local.get $s) (local.get $sn)) (i32.const 0)))

  ;; hex digit value or -1
  (func $nib (param $c i32) (result i32)
    (if (i32.and (i32.ge_u (local.get $c) (i32.const 48)) (i32.le_u (local.get $c) (i32.const 57)))
      (then (return (i32.sub (local.get $c) (i32.const 48)))))
    (if (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 102)))
      (then (return (i32.sub (local.get $c) (i32.const 87)))))
    (if (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 70)))
      (then (return (i32.sub (local.get $c) (i32.const 55)))))
    (i32.const -1))

  ;; write count as 16 hex chars (8 bytes, little endian) at dst; return end
  (func $put_hex_le (param $dst i32) (param $v i64) (result i32) (local $i i32) (local $b i32)
    (block $done (loop $l
      (br_if $done (i32.eq (local.get $i) (i32.const 8)))
      (local.set $b (i32.wrap_i64 (i64.and (i64.shr_u (local.get $v)
        (i64.extend_i32_u (i32.mul (local.get $i) (i32.const 8)))) (i64.const 255))))
      (i32.store8 (local.get $dst) (i32.load8_u (i32.add (i32.const 0x0260) (i32.shr_u (local.get $b) (i32.const 4)))))
      (i32.store8 (i32.add (local.get $dst) (i32.const 1))
        (i32.load8_u (i32.add (i32.const 0x0260) (i32.and (local.get $b) (i32.const 15)))))
      (local.set $dst (i32.add (local.get $dst) (i32.const 2)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (local.get $dst))

  ;; read 16 hex chars (8 bytes LE) at p; sets $hex_ok to 1 on success, 0 on bad input
  (func $get_hex_le (param $p i32) (param $end i32) (result i64)
    (local $i i32) (local $hi i32) (local $lo i32) (local $v i64)
    (if (i32.gt_s (i32.add (local.get $p) (i32.const 16)) (local.get $end))
      (then (global.set $hex_ok (i32.const 0)) (return (i64.const 0))))
    (block $done (loop $l
      (br_if $done (i32.eq (local.get $i) (i32.const 8)))
      (local.set $hi (call $nib (i32.load8_u (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 2))))))
      (local.set $lo (call $nib (i32.load8_u (i32.add (local.get $p) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))))))
      (if (i32.or (i32.lt_s (local.get $hi) (i32.const 0)) (i32.lt_s (local.get $lo) (i32.const 0)))
        (then (global.set $hex_ok (i32.const 0)) (return (i64.const 0))))
      (local.set $v (i64.or (local.get $v)
        (i64.shl (i64.extend_i32_u (i32.or (i32.shl (local.get $hi) (i32.const 4)) (local.get $lo)))
                 (i64.extend_i32_u (i32.mul (local.get $i) (i32.const 8))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (global.set $hex_ok (i32.const 1))
    (local.get $v))

  ;; write unsigned decimal at dst; return end
  (func $put_dec (param $dst i32) (param $v i64) (result i32) (local $tmp i32) (local $n i32)
    ;; digits are produced in reverse into 0x17f00.., then copied forward
    (local.set $tmp (i32.const 0x17f00))
    (loop $l
      (i32.store8 (i32.add (local.get $tmp) (local.get $n))
        (i32.add (i32.const 48) (i32.wrap_i64 (i64.rem_u (local.get $v) (i64.const 10)))))
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (local.set $v (i64.div_u (local.get $v) (i64.const 10)))
      (br_if $l (i64.ne (local.get $v) (i64.const 0))))
    (block $done (loop $c
      (br_if $done (i32.eqz (local.get $n)))
      (local.set $n (i32.sub (local.get $n) (i32.const 1)))
      (i32.store8 (local.get $dst) (i32.load8_u (i32.add (local.get $tmp) (local.get $n))))
      (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
      (br $c)))
    (local.get $dst))

  ;; parse unsigned decimal at p (stops at first non-digit)
  (func $get_dec (param $p i32) (param $end i32) (result i64) (local $v i64) (local $c i32)
    (block $done (loop $l
      (br_if $done (i32.ge_u (local.get $p) (local.get $end)))
      (local.set $c (i32.load8_u (local.get $p)))
      (br_if $done (i32.or (i32.lt_u (local.get $c) (i32.const 48)) (i32.gt_u (local.get $c) (i32.const 57))))
      (local.set $v (i64.add (i64.mul (local.get $v) (i64.const 10)) (i64.extend_i32_u (i32.sub (local.get $c) (i32.const 48)))))
      (local.set $p (i32.add (local.get $p) (i32.const 1)))
      (br $l)))
    (local.get $v))

  (func $call_const (param $p i32) (result i64)
    (call $host_call (local.get $p) (call $strlen (local.get $p))))

  ;; 1 if c is one of A-Z a-z 0-9 . _ : -
  (func $sid_char (param $c i32) (result i32)
    (i32.or
      (i32.or (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))
              (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122))))
      (i32.or (i32.and (i32.ge_u (local.get $c) (i32.const 48)) (i32.le_u (local.get $c) (i32.const 58)))   ;; 0-9 and ':'
              (i32.or (i32.or (i32.eq (local.get $c) (i32.const 46)) (i32.eq (local.get $c) (i32.const 95)))
                      (i32.eq (local.get $c) (i32.const 45))))))

  ;; take "surfaceId":"<id>" from the init / resume message into 0x0c00; 1 = ok, 0 = none / unusable
  (func $read_sid (param $p i32) (param $n i32) (result i32) (local $i i32) (local $s i32) (local $end i32) (local $k i32) (local $c i32)
    (local.set $i (call $find (local.get $p) (local.get $n) (i32.const 0x0b00) (i32.const 13)))
    (if (i32.ge_s (local.get $i) (i32.const 0))
      (then
        (local.set $s (i32.add (local.get $p) (i32.add (local.get $i) (i32.const 13))))
        (local.set $end (i32.add (local.get $p) (local.get $n)))
        (block $bad (loop $l
          (br_if $bad (i32.ge_u (i32.add (local.get $s) (local.get $k)) (local.get $end)))
          (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $k))))
          (if (i32.eq (local.get $c) (i32.const 34))          ;; closing quote
            (then
              (br_if $bad (i32.eqz (local.get $k)))
              (drop (call $copy (i32.const 0x0c00) (local.get $s) (local.get $k)))
              (global.set $sid_len (local.get $k))
              (return (i32.const 1))))
          (br_if $bad (i32.eqz (call $sid_char (local.get $c))))
          (local.set $k (i32.add (local.get $k) (i32.const 1)))
          (br_if $bad (i32.gt_u (local.get $k) (i32.const 64)))
          (br $l)))))
    (global.set $sid_len (i32.const 0))
    (i32.const 0))

  ;; copy a NUL-terminated template to dst, writing the surfaceId at each 0x01; return end
  (func $put_tmpl (param $dst i32) (param $src i32) (result i32) (local $c i32)
    (block $done (loop $l
      (local.set $c (i32.load8_u (local.get $src)))
      (br_if $done (i32.eqz (local.get $c)))
      (if (i32.eq (local.get $c) (i32.const 1))
        (then (local.set $dst (call $copy (local.get $dst) (i32.const 0x0c00) (global.get $sid_len))))
        (else (i32.store8 (local.get $dst) (local.get $c))
              (local.set $dst (i32.add (local.get $dst) (i32.const 1)))))
      (local.set $src (i32.add (local.get $src) (i32.const 1)))
      (br $l)))
    (local.get $dst))

  (func $call_tmpl (param $src i32) (result i64) (local $e i32)
    (local.set $e (call $put_tmpl (i32.const 0x10000) (local.get $src)))
    (call $host_call (i32.const 0x10000) (i32.sub (local.get $e) (i32.const 0x10000))))

  ;; ---- applet actions ----
  (func $publish_count (local $e i32)
    (local.set $e (call $put_tmpl (i32.const 0x10000) (i32.const 0x0900)))
    (local.set $e (call $put_dec (local.get $e) (global.get $count)))
    (local.set $e (call $copy (local.get $e) (i32.const 0x0a00) (i32.const 4)))
    (drop (call $host_call (i32.const 0x10000) (i32.sub (local.get $e) (i32.const 0x10000)))))

  (func $save_count (local $e i32)
    (local.set $e (call $copy (i32.const 0x10000) (i32.const 0x0200) (i32.const 43)))
    (local.set $e (call $put_hex_le (local.get $e) (global.get $count)))
    (local.set $e (call $copy (local.get $e) (i32.const 0x0240) (i32.const 2)))
    (drop (call $host_call (i32.const 0x10000) (i32.sub (local.get $e) (i32.const 0x10000)))))

  (func $boot (local $r i64)
    (drop (call $call_tmpl (i32.const 0x0300)))
    (drop (call $call_tmpl (i32.const 0x0400)))
    (global.set $count (i64.const 0))
    (call $publish_count)
    (local.set $r (call $call_const (i32.const 0x01c0)))
    (global.set $boot_id (if (result i64) (i64.lt_s (local.get $r) (i64.const 0))
      (then (i64.const -1)) (else (local.get $r)))))

  (func $on_host_result (param $p i32) (param $n i32) (local $i i32) (local $end i32) (local $v i64)
    (local.set $end (i32.add (local.get $p) (local.get $n)))
    (if (i64.lt_s (global.get $boot_id) (i64.const 0)) (then (return)))
    (local.set $i (call $find (local.get $p) (local.get $n) (i32.const 0x0120) (i32.const 5)))
    (if (i32.lt_s (local.get $i) (i32.const 0)) (then (return)))
    (if (i64.ne (call $get_dec (i32.add (local.get $p) (i32.add (local.get $i) (i32.const 5))) (local.get $end))
                (global.get $boot_id))
      (then (return)))
    (global.set $boot_id (i64.const -1))
    (local.set $i (call $find (local.get $p) (local.get $n) (i32.const 0x0140) (i32.const 9)))
    (if (i32.lt_s (local.get $i) (i32.const 0)) (then (return)))   ;; notFound or null: keep 0
    (call $get_hex_le (i32.add (local.get $p) (i32.add (local.get $i) (i32.const 9))) (local.get $end))
    (local.set $v)
    (if (global.get $hex_ok) (then (global.set $count (local.get $v)) (call $publish_count))))

  (func $restore_snapshot (param $p i32) (param $n i32) (local $i i32) (local $v i64)
    (local.set $i (call $find (local.get $p) (local.get $n) (i32.const 0x0160) (i32.const 12)))
    (if (i32.lt_s (local.get $i) (i32.const 0)) (then (return)))
    (call $get_hex_le (i32.add (local.get $p) (i32.add (local.get $i) (i32.const 12)))
                      (i32.add (local.get $p) (local.get $n)))
    (local.set $v)
    (if (global.get $hex_ok) (then (global.set $count (local.get $v)) (call $publish_count))))

  (func $reply (param $p i32) (param $n i32) (result i64)
    (i64.or (i64.shl (i64.extend_i32_u (local.get $p)) (i64.const 32)) (i64.extend_i32_u (local.get $n))))

  (func $handle (param $p i32) (param $n i32) (result i64) (local $e i32)
    (if (call $has (local.get $p) (local.get $n) (i32.const 0x0000) (i32.const 13))
      (then
        (if (i32.eqz (call $read_sid (local.get $p) (local.get $n)))
          (then (return (call $reply (i32.const 0x0b20) (i32.const 22)))))
        (call $boot)
        (return (call $reply (i32.const 0x0180) (i32.const 11)))))
    (if (call $has (local.get $p) (local.get $n) (i32.const 0x0020) (i32.const 15))
      (then
        (if (i32.eqz (call $read_sid (local.get $p) (local.get $n)))
          (then (return (call $reply (i32.const 0x0b20) (i32.const 22)))))
        (call $boot) (call $restore_snapshot (local.get $p) (local.get $n))
            (return (call $reply (i32.const 0x0180) (i32.const 11)))))
    (if (call $has (local.get $p) (local.get $n) (i32.const 0x0040) (i32.const 14))
      (then
        (if (call $has (local.get $p) (local.get $n) (i32.const 0x00a0) (i32.const 9))
          (then
            (if (call $has (local.get $p) (local.get $n) (i32.const 0x00c0) (i32.const 25))
              (then (global.set $count (i64.add (global.get $count) (i64.const 1)))
                    (call $save_count) (call $publish_count)))
            (if (call $has (local.get $p) (local.get $n) (i32.const 0x00e0) (i32.const 21))
              (then (global.set $count (i64.const 0))
                    (call $save_count) (call $publish_count))))
          (else
            (if (call $has (local.get $p) (local.get $n) (i32.const 0x0100) (i32.const 13))
              (then (call $on_host_result (local.get $p) (local.get $n))))))
        (return (call $reply (i32.const 0x0180) (i32.const 11)))))
    (if (call $has (local.get $p) (local.get $n) (i32.const 0x0080) (i32.const 16))
      (then
        (i32.store8 (i32.const 0x18000) (i32.const 123))               ;; '{'
        (local.set $e (call $copy (i32.const 0x18001) (i32.const 0x0160) (i32.const 12)))
        (local.set $e (call $put_hex_le (local.get $e) (global.get $count)))
        (local.set $e (call $copy (local.get $e) (i32.const 0x0240) (i32.const 2)))  ;; '"}'
        (return (call $reply (i32.const 0x18000) (i32.sub (local.get $e) (i32.const 0x18000))))))
    (if (call $has (local.get $p) (local.get $n) (i32.const 0x0060) (i32.const 17))
      (then (global.set $boot_id (i64.const -1))
            (return (call $reply (i32.const 0x0180) (i32.const 11)))))
    (call $reply (i32.const 0x01a0) (i32.const 18)))

  ;; ---- ABI exports ----
  ;; Input buffers come from a bump heap in page 0. The heap is reset after
  ;; every claw_on_event call, so it never grows across events.
  (func (export "claw_alloc") (param $n i32) (result i32) (local $p i32)
    (if (i32.or (i32.lt_s (local.get $n) (i32.const 0))
                (i32.gt_u (i32.add (global.get $bump) (local.get $n)) (i32.const 0x10000)))
      (then (return (i32.const 0))))
    (local.set $p (global.get $bump))
    (global.set $bump (i32.add (global.get $bump) (local.get $n)))
    (local.get $p))

  (func (export "claw_free") (param i32 i32))

  (func (export "claw_on_event") (param $p i32) (param $n i32) (result i64) (local $r i64)
    (local.set $r (call $handle (local.get $p) (local.get $n)))
    (global.set $bump (i32.const 0x1000))
    (local.get $r))
)
