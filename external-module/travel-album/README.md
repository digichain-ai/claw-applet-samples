# travel-album.wasm

The logic module of an interactive travel album applet, published **compiled only**.
Its source is not part of this repository. It is here so that a platform can be tested
with a realistic external module (admission, digest check, and opening an album with
real content), not only with the hand-written hello-counter.

| Item | Value |
|---|---|
| File | `travel-album.wasm`, 206632 bytes |
| SHA-256 | `bec2316d146ecdf4a17bbd5d38a9f6149600705833c1db09a8d798356dd20100` |
| ABI | `claw-applet/1`; the only import is `claw.claw_host_call` |
| Capabilities it uses | `ui`, `asset.read`, `playback.control`, `storage.kv` |
| Actions it handles | `applet.ready`, `slideshow.prev`, `slideshow.next`, `applet.view.toggle`, `applet.quiz.a`, `applet.quiz.b`, `applet.quiz.select` |
| Built with | rustc 1.94.0, target `wasm32-unknown-unknown`, `SOURCE_DATE_EPOCH=1704067200` |
| Signed | No. A platform checks the digest and signs its own manifest after admission. |

## Behaviour of this build

This is the edited build of the album rule: **`slideshow.next` moves forward two pages**
instead of one. A test that expects one page per Next fails against this module; a test
that expects two pages passes. That makes it useful for checking that a host really runs
the module it was given.

Start it with `{"kind":"init"}`, then send the `applet.ready` action. The album pages come from the host's media manifest (`asset.read`);
with an empty manifest the album has no pages.

## Notes

- The module contains panic-location strings with relative source file names
  (for example `crates/claw-applet-sdk/src/host.rs`) and generic toolchain paths
  (`/rustc/<hash>/library/...`, `/cargo/registry/...`). These are names only; no
  source code is included.
- It is not rebuilt by `build.sh`; `build.sh` only prints its SHA-256 so it can be
  checked against `SHA256SUMS`.
