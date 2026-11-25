# l3-upgrade-vector (v1 / v2 / v3)

Three versions of **one** logic module, written to test how a host handles an
applet **upgrade** that changes the shape of the saved state. Hand-written
WebAssembly text (`.wat`); each `.wasm` is the compiled bytes of the `.wat`
next to it. ABI `claw-applet/1`, capability `ui` only, no WASI, no assets.

| File | Package version | `logic.state.schema` | Bytes | SHA-256 |
|---|---|---|---|---|
| `v1.wasm` | 1.0.0 | 1 | 3033 | `ebc320cf502e94638f79a12c44c85bde72f75f4542f2d6129e34e3ff2fcd147b` |
| `v2.wasm` | 1.0.1 | 2 | 3615 | `c91b77e546c7686a534339d0b2ebffe6c5c55ee0de5feb4bdad268179728700e` |
| `v3.wasm` | 1.0.2 | 3 | 3076 | `5b00384b5a79a2795225e03a86cf614486a0419c1fa570bce4333d1ae5014f4e` |

## What each version does

All three show one screen: a title, a status line
`schema N · <init|resume|migrated> · count N`, and a **+1** button that sends
the action `applet.increment`. The `surfaceId` comes from the context; it
defaults to `main`. The text contains no personal data.

- **v1** — `init` sets the count to 1. Snapshot = `[0x01, count u32 LE]` (5 bytes).
  Accepts only its own snapshot.
- **v2** — given a schema-1 snapshot, the resume context must carry
  `"fromSchema":1` and a 64-hex `fromModuleSha256`; v2 then migrates to schema 2,
  keeps the count and shows "migrated 1→2 (from <first 8 hex of old module>)".
  Snapshot = `[0x02, count u32 LE, origin]` (6 bytes). When resuming its **own**
  snapshot it rejects a context that still carries `fromSchema` /
  `fromModuleSha256`, so a plain resume returning 0 proves the host dropped
  those fields after the upgrade.
- **v3** — rejects any upgrade context with `{"err":"schema 3 rejects upgrade"}`;
  the host is then expected to discard the instance and cold-start `init`
  (`schema 3 · init · count 1`). Snapshot = `[0x03, count u32 LE]`.

## Expected host behaviour (v1 → v2 → v3)

1. v1 init → count 1; tap +1 twice → count 3; suspend → snapshot `0103000000`.
2. Upgrade to v2 with the upgrade context → resume returns 0, screen shows
   "migrated 1→2" and count 3.
3. Upgrade to v3 → resume is rejected; the host cold-starts v3 → count 1.

## Check

```sh
sha256sum -c SHA256SUMS
```

The `.wasm` files were compiled from the `.wat` files with the Rust `wat` crate
(1.x); other assemblers such as `wat2wasm` may emit different but equivalent bytes.

The `.wat` comments are in Chinese. These are test inputs, not product code.
