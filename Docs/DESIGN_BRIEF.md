# MokaScreen — Design Brief

mokascreen.com. Free macOS app that turns a second MacBook into a low-latency extended display for the first, over a Thunderbolt cable. This brief describes the design as of 0.1.25; the original plan's spikes are all done, and what they and later measurements found is recorded below.

## Targets and constraints

- **Hardware:** designed and measured on two 16" M5 Max MacBook Pros (3456×2234 native, 120 Hz ProMotion) over Thunderbolt 5. Any MacBook that runs macOS 27.2 with Thunderbolt 4 or 5 should work; a display Mac with a 60 Hz screen gives a 60 Hz extended display, and over Thunderbolt 4 whole-screen changes fall below 120 fps.
- **OS:** macOS 27.2+. MokaScreen has only been run on 27.2, and the private CGVirtualDisplay API it uses was mapped there.
- **No recoveryOS changes, no kexts, no entitlements requiring Apple approval.** RDMA over Thunderbolt is ruled out because it requires recoveryOS enablement.
- One machine may be MDM-managed (work Mac); the app must be a normal user-space app.
- Language: Swift throughout (the private CGVirtualDisplay declarations are an Objective-C header).

## Measured transport (Thunderbolt Bridge, TCP, link-local, default MTU)

- Single stream: ~69 Gbps, 0 retransmits.
- 4 parallel streams: 67.8 Gbps total — link-bound, not CPU-bound. **Use one TCP connection.**
- 30-min bidirectional soak: 67.2 / 68.1 Gbps simultaneously; worst 1 s dip ~56 Gbps; one retransmit event (2650) at ~1140 s; no stalls or crashes.
- In use, per frame: a scroll changes about 80% of the screen, ~26 MB a frame, which took 4–5 ms on the cable typically and up to 16 ms at worst; per-frame throughput varied 35–75 Gbps. That variation, not the average, is what Smooth Motion exists for.

## Bandwidth math

- One full frame, 3456×2234 BGRA: ~31 MB.
- Raw 60 Hz ≈ 15 Gbps; raw 120 Hz ≈ 30 Gbps. Fits with >2× headroom → **no video encoder.**
- Full frame on the wire ≈ 3.6 ms (43% of a 120 Hz frame) → dirty rects matter for **latency**, not bandwidth.

## Architecture

**Sender (the Mac you work on)**
- `CGVirtualDisplay` (private CoreGraphics API, no driver) sized to the display Mac's screen, which it advertises over Bonjour: a HiDPI mode at the display Mac's refresh rate, capped at 120 Hz, plus 60 Hz.
- ScreenCaptureKit `SCStream` on that display's `CGDirectDisplayID`; `SCStreamFrameInfo.dirtyRects` feed a tile grid (`DirtyRegion`). Each frame carries ScreenCaptureKit's presentation time as its capture time.
- Lossless raw rects, written with `writev` straight from the capture buffer. Changes covering more than 85% of the screen go as one full-frame rect.
- **Latest-frame-wins:** never queue behind a TCP stall; a newer capture replaces the waiting one and their dirty areas merge.

**Receiver (the display Mac)**
- Full-screen borderless window with a `CAMetalLayer`, shown directly (no WindowServer compositing). The reader receives straight into eight GPU-shared slot buffers; each draw blits the frames it applies into a private display texture and draws that to the drawable.
- **Smooth Motion** (on by default): each frame is scheduled for its capture time (the virtual display's refresh, moved to the display Mac's clock by the synchronized offset) plus the smoothness margin — 20 ms by default (Settings › Smoothness margin: 15, 20, 25 or 30 ms), rising on its own to at most 30 ms if the 99th-percentile arrival of the last second needs more — moved to the panel's next refresh. A frame waits in its slot until a refresh before that time, so frames reach the glass spaced as they were captured. Until the clocks are synchronized the schedule counts from the smallest recent transit instead. Without Smooth Motion, frames are presented on arrival.
- **Refresh rate:** a display link pinned at 120 Hz (`RefreshRateRequest`, Settings › Hold the display at 120 Hz) holds the panel at 120 Hz while showing; its ticks give the refresh phase that Smooth Motion snaps to.
- **In flight:** up to two drawables (three under Smooth Motion). Each stops counting when macOS reports it on the glass, or one refresh after its scheduled time (two after the draw, if presented at once) when no report comes.
- **Keep-alive:** after 250 ms with no new frame, and every 250 ms while still, the unchanged picture is presented again, left out of the statistics.
- Switching to another app on the display Mac pauses the picture: frames are still received and applied to the texture, but not presented. Holding Esc for a second stops; a press of Esc is an ordinary key, so that it can be forwarded. Plain Esc was the exit through 0.1.33, and ⌘Esc in 0.1.34, where pressing it did nothing on the Mac it was tried on.
- On macOS 27.2, ⌘Tab from the picture to some apps (System Settings and Safari in the one test, not Terminal) is followed 40–50 ms later by macOS making MokaScreen the active app again; the cause is not known. An activation within 250 ms of a hide is treated as that bounce: MokaScreen yields to the app the user chose and keeps the picture hidden.
- **Keyboard and trackpad sharing** (Settings, off by default): while the picture is showing, the display Mac sends every key, pointer movement, click and scroll its window is given to the extending Mac as an `input` message, and the extending Mac posts the same event at the HID level (Accessibility permission), as if a second keyboard and trackpad were attached to it. Only what the window is given is forwarded, so ⌘Tab, Spotlight, Mission Control and the multi-finger swipes stay with the display Mac and no Input Monitoring permission is needed there. Pinch, rotate, smart zoom and Force click have no public event to post and are not forwarded. When forwarding stops, the extending Mac lets go of every key and button the display Mac was holding.

**Transport**
- Single TCP connection over Thunderbolt Bridge (`bridge0`), Nagle off, large socket buffers, behind `ByteStream` so the wire layer can change later.
- Fixed 32-byte message headers. Besides frames: `presented` acknowledgements carry each frame's glass time so the sender can time capture → glass without a shared clock; `clockPing`/`clockPong` four times a second give the display Mac the difference between the two host clocks (shortest recent round trip wins, slow exchanges ignored), so Smooth Motion's schedule is anchored to the connection's quickest trip instead of the recent frames' and does not shift when a scroll's large frames fill the window; `settings` keeps the display and statistics settings the same on both Macs; once-a-second display and pace reports; and, for Develop › Record Frame Timing, a timing request answered by one `frameTiming` report per frame.

## Findings that shaped the design

- **Virtual displays are fixed-rate.** On macOS 27.2, `CGVirtualDisplay`/`SLVirtualDisplay` modes each have one refresh rate. A sweep of 150 configurations (every `refreshDeadline` tried, every bit of the mode and display `options`, display type and subtype 1–7) all reported a fixed 8.333 ms refresh interval; WindowServer's log confirmed it received each setting. There is no ProMotion or variable refresh for a virtual display.
- **ProMotion does not deliver app frames off the 120 Hz grid.** The built-in panel reports a 8.3–41.7 ms range in 4.17 ms steps, but asked for 80 or 96 Hz it delivers 120, and presents scheduled 12.5 ms apart alternate 8.3 and 16.7 ms, windowed or full screen. A presented time between refreshes can land on a 4.17 ms half-step, hence snapping to refreshes.
- **Draw-on-arrival judders under large frames.** A frame timing recording of a slow scroll found captures exactly on 120 Hz ticks but 30.6% of frame pairs a refresh early or late on the glass, from the scroll frames' varying cable time. Smooth Motion took this to 0.5%; with the 20 ms minimum, a Finder scroll was 1 uneven pair in 775. The 20 ms minimum covers the first, largest frames of a scroll, which arrived 11–20 ms after the quickest; in later recordings no frame arrived more than 20 ms late.
- **The 60 Hz fallback.** Presenting on arrival without a display link, macOS sometimes ran the display Mac's panel at 60 Hz under a steady 110 fps load, about tripling its share of the delay; the pinned display link fixed it.
- **Lost presented reports after stillness.** After about a second with nothing presented, macOS 27.2 never calls the presented handler for the first one or two drawables presented, though the display link keeps ticking at 120 Hz. Waiting for those reports stalled drawing for up to 100 ms whenever motion resumed. Presenting the unchanged picture every 250 ms while still left no report missing in a probe (16 lost over 9 stills without it); the per-drawable deadline covers any that still go missing.
- **Stuck drawing on the display Mac.** Now and then `CAMetalLayer.nextDrawable()` on the display Mac starts taking its full one-second timeout for every drawable: one or two draws a second, no frame reported shown, the receive slots full and the sender's writes blocked for seconds. In the one occurrence with logs from both Macs (2026-11-21) the window was frontmost and not occluded, and the panel's EDR headroom had just finished ramping from 1.2 to 1.0; the cause is not known. A new window and layer cures it, so the display Mac rebuilds them when a second passes without a prompt drawable (at most every 10 s) and logs each slow drawable with the window's and screen's state under the `stall` category.
- **Comparisons.** AirPlay to Mac sets up its virtual display with 60 Hz modes, encodes at 60 fps, and compresses; Screen Sharing's High Performance mode is 30 or 60 fps. Sidecar is iPad-only.

## Measuring

- Settings › Developer mode adds the Develop menu with the tools below; the user-facing settings (Smooth Motion, smoothness margin, 120 Hz, statistics) are in Settings.
- Settings › Show statistics: rates, coverage, and capture → glass latency split into the cable (hand-off to end of write, timed on the extending Mac), Smooth Motion's hold, and the display Mac's own share.
- Develop › Record Frame Timing (⌥⌘T): 10 s of per-frame capture, send, arrival, draw, scheduled and glass times from both Macs, one CSV row per capture, in `~/Library/Logs/MokaScreen/`. Compare each pair of consecutive shown frames' glass spacing with their capture spacing; a difference over half a refresh is an uneven pair.
- Develop › Show Latency Clock: a millisecond clock on every screen, for filming glass-to-glass latency.

## Open items

- Not yet checked on purpose: `bridge0` and the connection recovering cleanly after sleep/wake (left over from the first spike).
- While the display Mac is paused, the extending Mac is not told: it still says "Extending to …" and its latency stops updating.
- With more than one configured bridge service, the first enabled one is used, which may not be the Thunderbolt one.
- Remaining unevenness (~0.5% of frame pairs): the first frame after a still moment lands one refresh late, and the schedule shifts by a refresh if frames arrive late enough for the delay to rise past the margin.

## References

- `CGVirtualDisplay` headers come from class-dumps; see FreeDisplay and Chromium's virtual display code for working usage. `refreshDeadline`, `isReference`, mode `transferFunction`, and SkyLight's `SLVirtualDisplay*` classes exist beyond what MokaScreen declares.
- Prior art: BetterDisplay, DisplayLink macOS software, Luna Display Mac-to-Mac mode, AirPlay to Mac.

## Code conventions

- No restatement comments.
- `///` doc comments on public API.
- "Why" comments, especially for platform bugs and private-API quirks.
- Prefer systemic solutions over one-off workarounds.
- The hot path (capture → wire → present) runs on dedicated threads; no allocation or locking in it.
