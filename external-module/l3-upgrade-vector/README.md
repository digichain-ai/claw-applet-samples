# l3-upgrade-vector (v1 / v2 / v3)

Three versions of **one** logic module, written to test how a host handles an
applet **upgrade** that changes the shape of the saved state. Hand-written
WebAssembly text (`.wat`); each `.wasm` is the compiled bytes of the `.wat`
next to it. ABI `claw-applet/1`, capability `ui` only, no WASI, no assets.

| File | Package version | `logic.state.schema` | Bytes | SHA-256 |
|---|---|---|---|---|
| `v1.wasm` | 1.0.0 | 1 | 3041 | `cc18f6017fb91599467ed77f50adfff219f4fc25e3fa0c19e706fa21ed08db27` |
| `v2.wasm` | 1.0.1 | 2 | 3624 | `95e94160c5bb1c5fdf26c92a9a5bde551246c5bf6c5d8c30bfb3a2dc76f1271a` |
| `v3.wasm` | 1.0.2 | 3 | 3084 | `c99e5ae3b8424c32c607e2d84db04f8200241eda586e976cced1ffd9af3f21e1` |

## What each version does

Each `ui.publish` carries **one** A2UI v0.9 envelope (not an array): `createSurface` once, then `updateComponents` (F26 host-api-v1.wit). All three show one screen: a title, a status line
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
