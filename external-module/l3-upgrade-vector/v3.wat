;; l3-upgrade-vector v3（版本 1.0.2，state schema 3）——F52 换版向量 L3，Plat 1125c。
;; ABI claw-applet/1：唯一导入 claw.claw_host_call；导出 memory、claw_alloc、claw_free、claw_on_event。
;; 事件（宿主送进来的 JSON）：{"kind":"init"|"resume"|"suspend"|"shutdown"|"event",...}。
;; 行为：init 置计数 1，一次 ui.publish 一屏（createSurface + updateComponents，屏上为 schema 号、生命周期来源与计数）；
;;       动作 applet.increment 计数 +1 并重发组件；suspend 回快照；resume 只收本版快照（且 context 不带换版字段）。
;; 换版：context 带 fromSchema / fromModuleSha256 的 resume 一律显式拒收，回 {"err":...}（库返回 -5），
;;       宿主释放该实例、新建实例冷启 init（F26 §7.1）。旧版快照同样拒收。
;; 快照 schema 3 = [0x03, count:u32 LE]，共 5 字节。
;; 只用 ui 能力，文案无个人内容。surfaceId 取 context，缺省 "main"。
(module
  (import "claw" "claw_host_call" (func $hc (param i32 i32) (result i64)))
  (memory (export "memory") 2)

  (global $count (mut i32) (i32.const 0))
  (global $how (mut i32) (i32.const 0))        ;; 0=init 1=resume
  (global $surf_len (mut i32) (i32.const 0))

  ;; ---- 常量（以 \00 结尾）----
  (data (i32.const 256)  "{\"kind\":\"suspend\"}\00")
  (data (i32.const 512)  "{\"kind\":\"shutdown\"}\00")
  (data (i32.const 768)  "\"kind\":\"init\"\00")
  (data (i32.const 1024) "\"kind\":\"resume\"\00")
  (data (i32.const 1280) "\"surfaceId\":\"\00")
  (data (i32.const 1536) "\"fromSchema\"\00")
  (data (i32.const 1792) "\"fromModuleSha256\"\00")
  (data (i32.const 2048) "\"snapshot\":\"\00")
  (data (i32.const 2304) "\"applet.increment\"\00")
  (data (i32.const 2560) "main\00")
  (data (i32.const 2816) "{\"op\":\"ui.publish\",\"envelope\":\"\00")
  (data (i32.const 3072) "\"}\00")
  (data (i32.const 3328) "{\"snapshot\":\"\00")
  (data (i32.const 3584) "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"\00")
  (data (i32.const 3840) "0123456789abcdef\00")
  (data (i32.const 4096) "\",\"catalogId\":\"desktop-ai:v1\"}}\00")
  (data (i32.const 4608) "{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"\00")
  (data (i32.const 5120) "\",\"components\":[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"title\",\"status\",\"inc\"]},{\"id\":\"title\",\"component\":\"Text\",\"text\":\"L3 换版向量 v3（1.0.2）\"},{\"id\":\"status\",\"component\":\"Text\",\"text\":\"schema 3 · \00")
  (data (i32.const 5632) "\"},{\"id\":\"inc\",\"component\":\"Button\",\"child\":\"incLabel\",\"action\":{\"event\":{\"name\":\"applet.increment\"}}},{\"id\":\"incLabel\",\"component\":\"Text\",\"text\":\"+1\"}]}}\00")
  (data (i32.const 6144) "init · 计数 \00")
  (data (i32.const 6400) "resume · 计数 \00")
  (data (i32.const 7424) "{\"err\":\"bad surfaceId\"}\00")
  (data (i32.const 7680) "{\"err\":\"unknown snapshot schema\"}\00")
  (data (i32.const 8192) "{\"err\":\"schema 3 rejects upgrade\"}\00")

  ;; ---- 工作区 ----
  ;; 8960 十进制暂存（16）；8976 快照字节（32）；9216 surfaceId（256）；10240 信封（8K）；18432 请求（16K）；34816 回包；65536 起为输入
  (func $zlen (param $s i32) (result i32) (local $n i32)
    (block $d (loop $l
      (br_if $d (i32.eqz (i32.load8_u (i32.add (local.get $s) (local.get $n)))))
      (local.set $n (i32.add (local.get $n) (i32.const 1))) (br $l)))
    (local.get $n))

  ;; 在 [h, h+hn) 中找 \00 结尾串 nd 的首个出现，返回绝对地址；无则 -1
  (func $find (param $h i32) (param $hn i32) (param $nd i32) (result i32)
    (local $i i32) (local $j i32) (local $c i32)
    (block $done (loop $outer
      (br_if $done (i32.gt_u (local.get $i) (local.get $hn)))
      (local.set $j (i32.const 0))
      (block $miss (loop $inner
        (local.set $c (i32.load8_u (i32.add (local.get $nd) (local.get $j))))
        (if (i32.eqz (local.get $c)) (then (return (i32.add (local.get $h) (local.get $i)))))
        (br_if $miss (i32.ge_u (i32.add (local.get $i) (local.get $j)) (local.get $hn)))
        (br_if $miss (i32.ne (local.get $c) (i32.load8_u (i32.add (local.get $h) (i32.add (local.get $i) (local.get $j))))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $inner)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $outer)))
    (i32.const -1))

  (func $has (param $p i32) (param $n i32) (param $nd i32) (result i32)
    (i32.ge_s (call $find (local.get $p) (local.get $n) (local.get $nd)) (i32.const 0)))

  ;; 输入恰等于串 s
  (func $eqz (param $p i32) (param $n i32) (param $s i32) (result i32)
    (if (i32.ne (local.get $n) (call $zlen (local.get $s))) (then (return (i32.const 0))))
    (i32.eq (call $find (local.get $p) (local.get $n) (local.get $s)) (local.get $p)))

  (func $emitn (param $d i32) (param $s i32) (param $n i32) (result i32)
    (block $x (loop $l
      (br_if $x (i32.eqz (local.get $n)))
      (i32.store8 (local.get $d) (i32.load8_u (local.get $s)))
      (local.set $d (i32.add (local.get $d) (i32.const 1)))
      (local.set $s (i32.add (local.get $s) (i32.const 1)))
      (local.set $n (i32.sub (local.get $n) (i32.const 1)))
      (br $l)))
    (local.get $d))

  (func $emitz (param $d i32) (param $s i32) (result i32)
    (call $emitn (local.get $d) (local.get $s) (call $zlen (local.get $s))))

  (func $emit_u32 (param $d i32) (param $v i32) (result i32) (local $t i32)
    (local.set $t (i32.const 8976))
    (loop $l
      (local.set $t (i32.sub (local.get $t) (i32.const 1)))
      (i32.store8 (local.get $t) (i32.add (i32.const 48) (i32.rem_u (local.get $v) (i32.const 10))))
      (local.set $v (i32.div_u (local.get $v) (i32.const 10)))
      (br_if $l (local.get $v)))
    (call $emitn (local.get $d) (local.get $t) (i32.sub (i32.const 8976) (local.get $t))))

  ;; 把 [s, e) 按 JSON 字符串转义写出（只需转 " 与 \；信封里无控制字符）
  (func $emit_esc (param $d i32) (param $s i32) (param $e i32) (result i32) (local $c i32)
    (block $x (loop $l
      (br_if $x (i32.ge_u (local.get $s) (local.get $e)))
      (local.set $c (i32.load8_u (local.get $s)))
      (if (i32.or (i32.eq (local.get $c) (i32.const 34)) (i32.eq (local.get $c) (i32.const 92)))
        (then (i32.store8 (local.get $d) (i32.const 92)) (local.set $d (i32.add (local.get $d) (i32.const 1)))))
      (i32.store8 (local.get $d) (local.get $c))
      (local.set $d (i32.add (local.get $d) (i32.const 1)))
      (local.set $s (i32.add (local.get $s) (i32.const 1)))
      (br $l)))
    (local.get $d))

  (func $hexval (param $c i32) (result i32)
    (if (i32.and (i32.ge_u (local.get $c) (i32.const 48)) (i32.le_u (local.get $c) (i32.const 57))) (then (return (i32.sub (local.get $c) (i32.const 48)))))
    (if (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 102))) (then (return (i32.sub (local.get $c) (i32.const 87)))))
    (if (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 70))) (then (return (i32.sub (local.get $c) (i32.const 55)))))
    (i32.const -1))

  (func $reply (param $p i32) (param $n i32) (result i64)
    (i64.or (i64.shl (i64.extend_i32_u (local.get $p)) (i64.const 32)) (i64.extend_i32_u (local.get $n))))
  (func $reply_z (param $s i32) (result i64)
    (call $reply (local.get $s) (call $zlen (local.get $s))))

  ;; 从 context 取 surfaceId 到 9216；缺省 "main"；含转义或过长则失败（返回 0）
  (func $surface (param $p i32) (param $n i32) (result i32) (local $k i32) (local $e i32) (local $c i32) (local $len i32)
    (local.set $k (call $find (local.get $p) (local.get $n) (i32.const 1280)))
    (if (i32.lt_s (local.get $k) (i32.const 0))
      (then (global.set $surf_len (i32.sub (call $emitz (i32.const 9216) (i32.const 2560)) (i32.const 9216))) (return (i32.const 1))))
    (local.set $k (i32.add (local.get $k) (call $zlen (i32.const 1280))))
    (local.set $e (i32.add (local.get $p) (local.get $n)))
    (block $x (loop $l
      (if (i32.ge_u (local.get $k) (local.get $e)) (then (return (i32.const 0))))
      (local.set $c (i32.load8_u (local.get $k)))
      (br_if $x (i32.eq (local.get $c) (i32.const 34)))
      (if (i32.or (i32.eq (local.get $c) (i32.const 92)) (i32.ge_u (local.get $len) (i32.const 200))) (then (return (i32.const 0))))
      (i32.store8 (i32.add (i32.const 9216) (local.get $len)) (local.get $c))
      (local.set $len (i32.add (local.get $len) (i32.const 1)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $l)))
    (if (i32.eqz (local.get $len)) (then (return (i32.const 0))))
    (global.set $surf_len (local.get $len))
    (i32.const 1))

  ;; 解 "snapshot":"<hex>" 到 8976，返回字节数；无或非法返回 -1
  (func $read_snap (param $p i32) (param $n i32) (result i32) (local $k i32) (local $e i32) (local $hi i32) (local $lo i32) (local $len i32)
    (local.set $k (call $find (local.get $p) (local.get $n) (i32.const 2048)))
    (if (i32.lt_s (local.get $k) (i32.const 0)) (then (return (i32.const -1))))
    (local.set $k (i32.add (local.get $k) (call $zlen (i32.const 2048))))
    (local.set $e (i32.add (local.get $p) (local.get $n)))
    (block $x (loop $l
      (if (i32.ge_u (local.get $k) (local.get $e)) (then (return (i32.const -1))))
      (br_if $x (i32.eq (i32.load8_u (local.get $k)) (i32.const 34)))
      (if (i32.ge_u (i32.add (local.get $k) (i32.const 1)) (local.get $e)) (then (return (i32.const -1))))
      (local.set $hi (call $hexval (i32.load8_u (local.get $k))))
      (local.set $lo (call $hexval (i32.load8_u (i32.add (local.get $k) (i32.const 1)))))
      (if (i32.or (i32.lt_s (local.get $hi) (i32.const 0)) (i32.lt_s (local.get $lo) (i32.const 0))) (then (return (i32.const -1))))
      (if (i32.ge_u (local.get $len) (i32.const 32)) (then (return (i32.const -1))))
      (i32.store8 (i32.add (i32.const 8976) (local.get $len)) (i32.or (i32.shl (local.get $hi) (i32.const 4)) (local.get $lo)))
      (local.set $len (i32.add (local.get $len) (i32.const 1)))
      (local.set $k (i32.add (local.get $k) (i32.const 2)))
      (br $l)))
    (local.get $len))

  ;; 把 [10240, e) 的信封包成 {"op":"ui.publish","envelope":"…"} 发出
  (func $send (param $e i32) (local $r i32)
    (local.set $r (call $emitz (i32.const 18432) (i32.const 2816)))
    (local.set $r (call $emit_esc (local.get $r) (i32.const 10240) (local.get $e)))
    (local.set $r (call $emitz (local.get $r) (i32.const 3072)))
    (drop (call $hc (i32.const 18432) (i32.sub (local.get $r) (i32.const 18432)))))

  ;; 一次发布；create=1 时先单独发 createSurface
  (func $publish (param $create i32) (local $e i32) (local $r i32)
    ;; F26 host-api-v1.wit：每次 ui.publish 只提交一条 A2UI v0.9 信封（不是数组）：createSurface 一次、updateComponents 一次。
    (if (local.get $create) (then
      (local.set $e (call $emitz (i32.const 10240) (i32.const 3584)))
      (local.set $e (call $emitn (local.get $e) (i32.const 9216) (global.get $surf_len)))
      (local.set $e (call $emitz (local.get $e) (i32.const 4096)))
      (call $send (local.get $e))))
    (local.set $e (call $emitz (i32.const 10240) (i32.const 4608)))
    (local.set $e (call $emitn (local.get $e) (i32.const 9216) (global.get $surf_len)))
    (local.set $e (call $emitz (local.get $e) (i32.const 5120)))
    (local.set $e (call $emitz (local.get $e) (select (i32.const 6400) (i32.const 6144) (global.get $how))))
    (local.set $e (call $emit_u32 (local.get $e) (global.get $count)))
    (local.set $e (call $emitz (local.get $e) (i32.const 5632)))
    (call $send (local.get $e)))

  ;; 把 8976 起 n 字节写成 {"snapshot":"<hex>"}
  (func $snap_reply (param $n i32) (result i64) (local $o i32) (local $i i32) (local $b i32)
    (local.set $o (call $emitz (i32.const 34816) (i32.const 3328)))
    (block $x (loop $l
      (br_if $x (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $b (i32.load8_u (i32.add (i32.const 8976) (local.get $i))))
      (i32.store8 (local.get $o) (i32.load8_u (i32.add (i32.const 3840) (i32.shr_u (local.get $b) (i32.const 4)))))
      (i32.store8 (i32.add (local.get $o) (i32.const 1)) (i32.load8_u (i32.add (i32.const 3840) (i32.and (local.get $b) (i32.const 15)))))
      (local.set $o (i32.add (local.get $o) (i32.const 2)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (local.set $o (call $emitz (local.get $o) (i32.const 3072)))
    (call $reply (i32.const 34816) (i32.sub (local.get $o) (i32.const 34816))))

  (func $on_init (param $p i32) (param $n i32) (result i64)
    (if (i32.eqz (call $surface (local.get $p) (local.get $n))) (then (return (call $reply_z (i32.const 7424)))))
    (global.set $count (i32.const 1))
    (global.set $how (i32.const 0))
    (call $publish (i32.const 1))
    (i64.const 0))

  ;; v3 只收本版快照；context 带换版字段即显式拒收（不迁移）
  (func $on_resume (param $p i32) (param $n i32) (result i64) (local $len i32)
    (if (i32.eqz (call $surface (local.get $p) (local.get $n))) (then (return (call $reply_z (i32.const 7424)))))
    (if (i32.or (call $has (local.get $p) (local.get $n) (i32.const 1536)) (call $has (local.get $p) (local.get $n) (i32.const 1792)))
      (then (return (call $reply_z (i32.const 8192)))))
    (local.set $len (call $read_snap (local.get $p) (local.get $n)))
    (if (i32.or (i32.ne (local.get $len) (i32.const 5)) (i32.ne (i32.load8_u (i32.const 8976)) (i32.const 3)))
      (then (return (call $reply_z (i32.const 7680)))))
    (global.set $count (i32.load align=1 (i32.const 8977)))
    (global.set $how (i32.const 1))
    (call $publish (i32.const 1))
    (i64.const 0))

  (func $on_suspend (result i64)
    (i32.store8 (i32.const 8976) (i32.const 3))
    (i32.store align=1 (i32.const 8977) (global.get $count))
    (call $snap_reply (i32.const 5)))

  (func (export "claw_alloc") (param $n i32) (result i32) (local $need i32)
    (local.set $need (i32.shr_u (i32.add (local.get $n) (i32.const 131071)) (i32.const 16)))
    (if (i32.gt_u (local.get $need) (memory.size))
      (then (if (i32.lt_s (memory.grow (i32.sub (local.get $need) (memory.size))) (i32.const 0)) (then unreachable))))
    (i32.const 65536))

  (func (export "claw_free") (param i32 i32))

  (func (export "claw_on_event") (param $p i32) (param $n i32) (result i64)
    (if (call $eqz (local.get $p) (local.get $n) (i32.const 256)) (then (return (call $on_suspend))))
    (if (call $eqz (local.get $p) (local.get $n) (i32.const 512)) (then (return (i64.const 0))))
    (if (call $has (local.get $p) (local.get $n) (i32.const 768)) (then (return (call $on_init (local.get $p) (local.get $n)))))
    (if (call $has (local.get $p) (local.get $n) (i32.const 1024)) (then (return (call $on_resume (local.get $p) (local.get $n)))))
    ;; 其余为 kind=event：动作 applet.increment 计数 +1；hostResult 等一律忽略
    (if (call $has (local.get $p) (local.get $n) (i32.const 2304))
      (then (global.set $count (i32.add (global.get $count) (i32.const 1))) (call $publish (i32.const 0))))
    (i64.const 0))
)
