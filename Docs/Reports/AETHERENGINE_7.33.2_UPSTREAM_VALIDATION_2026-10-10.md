# AetherEngine 7.33.2 upstream validation

Date: 2026-10-10

Status: the 7.33.2 upstream pin remains accepted. On 2026-10-11 downstream
Patch 0005 was rewritten around the measured ONE CDN contract: one
reader-lifetime HTTP/1.1 keep-alive session for the admitted query-wrapped
segment sequence. The direct Aether physical-device smoke now passes on the
authorized study-room Apple TV. No Syncnext release, TestFlight upload, push,
or publication is part of this work.

## Candidate identity

- AetherEngine release: `7.33.2`
- AetherEngine commit: `e7afcfad3973426a6ffff31fc111f6b1e5078061`
- FFmpegBuild release: `3.7.0`
- FFmpegBuild commit: `9baf6d00611548ddfbbabda19493d9ff36d336c1`
- Physical-device surface: authorized study-room Apple TV, tvOS 26.6, arm64

Evidence is stored outside the tracked tree under
`.validation/aether-7.33.2-20261010/` in the isolated Hybrid and Syncnext
worktrees.

## Patch compatibility

The existing downstream responsibilities were reconstructed against the
7.33.2 source instead of accepting fuzzy patch application. The active series
contains:

| Patch | Preserved responsibility |
| --- | --- |
| `0001-local-ffmpegbuild.patch` | Keeps AetherEngine on the exact sibling FFmpegBuild 3.7.0 checkout and prevents a remote duplicate. |
| `0002-independent-audio-source.patch` | Keeps the independent, seekable VOD audio source contract. |
| `0004-cache-backed-fingerprint-audio.patch` | Keeps bounded, cache-backed fingerprint PCM extraction on the current upstream cache model. |
| `0005-query-wrapped-hls-segment-ingest.patch` | Admits only finite HLS playlists whose query-wrapped MPEG-TS segments have positive HEVC evidence, then streams the same-origin sequence through one reader-lifetime HTTP/1.1 keep-alive connection. Superseded opening generations drain their current response to its framing boundary before the successor reuses the socket; refusals are terminal and are not retried on another protocol or route. Live, fMP4, H.264, encrypted, and ambiguous inputs keep their existing routes. |

Two clean temporary-index patch replays produced byte-identical patched states
at Aether diff hash
`2b56e06379f6c2335cdc71170e1ac6b65617dd313b9396a1cfe1a496ad82aeea`.
The manifest, official remotes, exact detached pins, and local-only dependency
graph checks passed. A full `apply-patches.sh` run passed 95 Hybrid tests and
the generic tvOS build before the final reader-lifetime delta. The final-hash
run completed patch check/apply and product build, then stalled during the
existing Hybrid tests amid repeated system Contacts XPC failures; no assertion
failed before the hang. An immediately preceding replay was stack-sampled in
`HLSExtractorTestServer.stop()` / `Process.waitUntilExit()` after its Python
child had already exited. These environmental hangs are recorded instead of
being reported as a final full-suite pass.

## Automated validation

| Surface | Result |
| --- | --- |
| Query-wrapped HLS focused Aether tests | PASS: 50 executed across XCTest and Swift Testing, 0 failures. Includes one accepted connection for three requests, no `Range`, terminal 403 without retry, immediate close on reader cancellation, and drain/reuse across a superseded generation. |
| SyncnextHybrid tests | Last complete run: 95 executed, 2 fixture-gated skips, 0 failures. The final-hash run was blocked by the test-environment hang described above; no test assertion failed before it stopped progressing. |
| Generic Hybrid tvOS build | PASS before the final reader-lifetime delta; final signed HybridSmokePlayer tvOS build PASS with the final patch. |
| HybridSmokePlayer direct Aether | PASS on study-room Apple TV: startup +2.000 s, 10 s seek landed at 9.880 s, strict post-seek +2.020 s, terminal `run_passed`. |
| HybridSmokePlayer native route | PASS: `nativeAVPlayer` remained stable after seek. |
| HybridSmokePlayer proxy route | PASS: `avKitProxy` reached Aether and progressed after seek. |
| Signed Syncnext tvOS build | PASS against the isolated Hybrid checkout. |
| Independent audio contract | PASS in the replayed Hybrid suite. |

## Syncnext physical-device seek and EOS acceptance

The repository-owned acceptance runner installed the signed candidate only on
the authorized study-room Apple TV. Both selected five-minute fixtures kept
their expected route, completed forward and backward seeks, demonstrated
continuous post-seek media-time progress, and reached natural EOS. The final
summary is `2 passed, 0 non-passing`.

| Case | Route | Seek results | EOS result |
| --- | --- | --- | --- |
| H.264/AAC progressive MP4 | `nativeAVPlayer` | Forward and backward seek applied; 2.017 / 2.000 seconds post-seek progress. | Ended at 299.965 seconds with stable player, session, and source identity. |
| interlaced MPEG-2/AC-3 Matroska | `avKitProxy` | Forward and backward seek applied; 2.048 / 2.056 seconds post-seek progress. | Ended at 299.624 seconds with stable player, session, and source identity. |

Primary evidence:

- `promotion-evidence.json`
- Syncnext `syncnext-minimal-eos-run2/summary.json`
- Syncnext `syncnext-minimal-eos-run2/cases/*/events.jsonl`

## Live ONE boundary

The live ONE source is now the direct physical-device acceptance fixture. A
fresh plugin resolution selected `cn1.ifn.watch`; admission resolved 120
segments / 1203.28 seconds at 3840×2160. libavformat superseded the opening
producer twice at time zero. Producer-lifetime sessions reproduced 403 on the
third first-segment request; reader-lifetime ownership instead completed that
request as `protocol=http/1.1 connectionReused=true status=200` (4,103,664
bytes in 10.689 seconds). Subsequent completed segments stayed on the same H1
connection and returned 200, including 3,836,704 bytes in 5.280 seconds and
6,380,344 bytes in 8.284 seconds. The fixed smoke contract then passed startup,
seek landing, and post-seek progress. No retry, inner-URL bypass, HTTP/2 path,
or alternate player route was used. The temporary experiment that disabled
intro/outro analysis remains fully reverted.

The final ONE runtime log and before/after device captures are under
`.validation/aether-7.33.2-20261010/one-cn1-reader-session-http1/` in the
`aether-querywrapped-http1-replay-20261011` isolated worktree.

## Formal verdict

The AetherEngine 7.33.2 pin remains accepted. Patch 0005 now satisfies the
requested ONE direct-Aether device surface and is reproducible at hash
`9cb48dfdff84aa917a0ca89833c37d12295246460b4b88e8ea1a5fa0ed4eb8e3`.
It is ready for continued integration testing. A full promotion verdict remains
pending one clean completion of the final-hash Hybrid suite because the two
latest replay attempts were blocked by unrelated test-environment hangs, not
by a failing assertion.
