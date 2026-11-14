# MokaScreen — Design Brief (handoff)

mokascreen.com. Free macOS app that turns a second MacBook into a low-latency extended display for the first, over a Thunderbolt 5 cable.

## Targets and constraints

- **Hardware:** M5 Pro/Max MacBook Pro 16" (3456×2234 native, 120 Hz) on both ends. Older Macs are explicitly unsupported.
- **OS:** macOS 27.2+. MokaScreen has only been run on 27.2, and the private CGVirtualDisplay API it uses was mapped there.
- **No recoveryOS changes, no kexts, no entitlements requiring Apple approval.** RDMA over Thunderbolt is ruled out because it requires recoveryOS enablement.
- One machine may be MDM-managed (work Mac); the app must be a normal user-space app.
- Language: Swift throughout.

## Measured transport (Thunderbolt Bridge, TCP, link-local, default MTU)

- Single stream: ~69 Gbps, 0 retransmits.
- 4 parallel streams: 67.8 Gbps total — link-bound, not CPU-bound. **Use one TCP connection.**
- 30-min bidirectional soak: 67.2 / 68.1 Gbps simultaneously; worst 1 s dip ~56 Gbps; one retransmit event (2650) at ~1140 s; no stalls or crashes.

## Bandwidth math

- One full frame, 3456×2234 BGRA: ~31 MB.
- Raw 60 Hz ≈ 15 Gbps; raw 120 Hz ≈ 30 Gbps. Fits with >2× headroom → **no video encoder.**
- Full frame on the wire ≈ 3.6 ms (43% of a 120 Hz frame) → dirty rects matter for **latency**, not bandwidth.

## Architecture

**Sender (the Mac you work on)**
- `CGVirtualDisplay` (private CoreGraphics API, no driver) with a native 3456×2234 HiDPI mode at 120 Hz.
- ScreenCaptureKit `SCStream` on that display's `CGDirectDisplayID`; use `SCStreamFrameInfo.dirtyRects`.
- Send lossless dirty rects (raw, optional LZ4). Large changes: send full frame as pipelined tiles so the receiver starts blitting early.
- **Latest-frame-wins:** never queue behind a TCP stall; drop stale frames.

**Receiver (the display Mac)**
- Full-screen `CAMetalLayer`, IOSurface-backed buffer ring, blit incoming regions.
- Paced by `CADisplayLink` at 120 Hz; always present newest complete frame.

**Transport**
- Single TCP connection over Thunderbolt Bridge (`bridge0`), Nagle off, large socket buffers.
- Abstract it behind a protocol so the wire layer can change later.

## Spikes, in order

1. ~~iperf3 over Thunderbolt Bridge~~ — done (results above). Still to check: `bridge0` recovers cleanly after sleep/wake.
2. `CGVirtualDisplay`: create it, confirm macOS offers 120 Hz HiDPI modes, confirm windows/Spaces behave.
3. `SCStream` on the virtual display: log dirty-rect sizes during real daily work.
4. End-to-end path; measure glass-to-glass latency with a high-speed phone camera filming both screens.

## References

- `CGVirtualDisplay` headers come from class-dumps; see FreeDisplay and Chromium's virtual display code for working usage.
- Prior art: BetterDisplay, DisplayLink macOS software, Luna Display Mac-to-Mac mode, AirPlay to Mac.

## Code conventions

- No restatement comments.
- `///` doc comments on public API.
- "Why" comments, especially for platform bugs and private-API quirks.
- Prefer systemic solutions over one-off workarounds.
