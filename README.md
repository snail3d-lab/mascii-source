> **You bought source access.** Read [BUYER.md](BUYER.md) and [LICENSE.md](LICENSE.md) first.

# Mascii

Turn any video into ASCII art, live on your phone's GPU. No cloud. No servers.
No accounts.

Built on the bitmap-atlas trick from the Metropolis experiment (see
`metropolis-ascii/` — the Python prototype that rendered the whole 1927 film
on a laptop at ~70ms/frame): each character cell's luminance is quantized to
12 levels and the glyph is gathered from a pre-rendered atlas in a single Metal
compute pass. A17-class silicon does the whole 1080×1920 frame in ~2–5 ms.

## Features

- **Live player** — pick any video from your library, watch it as ASCII art in real time
  (30 fps display, 24 fps source cadence)
- **Overnight render** — full-length videos render to an MP4 on device (the "overnight mode")
- **Free tier** — videos up to 2 minutes, free
- **Mascii Pro** — one-time $9.99 unlock (non-consumable IAP) for longer videos

## Architecture

```
AVAssetReader (source video, BGRA)
        │
        ▼
VideoPipeline ── CPU luminance downscale to (cellCols × cellRows) gray image
        │
        ▼
AsciiRenderer::uploadCellImage ── Metal R8 texture
        │
        ▼
ascii_fragment.metal (one compute pass, 1 thread/pixel)
   - map pixel → cell
   - quantize luminance → 12-level palette
   - gather glyph from 12-tile atlas texture
   - flicker · vignette · grain
        │
        ▼
   MTKView drawable (live) / AVAssetWriter (offline MP4)
```

| File | What it is |
|---|---|
| `Mascii/Metal/ascii.metal` | The GPU kernel. The whole aesthetic lives here. |
| `Mascii/AsciiRenderer.swift` | Metal device/pipeline/atlas ownership, render entry points |
| `Mascii/VideoPipeline.swift` | AVAssetReader + luminance downscale |
| `Mascii/Views/PlayerView.swift` | Live MTKView player (UIViewRepresentable) |
| `Mascii/OfflineEncoder.swift` | Overnight MP4 encoder (cancellable, progress) |
| `Mascii/Views/ContentView.swift` | Dark-theme UI, video picker, brightness |
| `Mascii/Views/PaywallView.swift` | StoreKit 2 paywall |
| `Mascii/MasciiApp.swift` | App entry + PurchaseStore (free 2 min / $9.99 unlock) |

## Pricing model

- **Free:** any video ≤ 2 minutes
- **$9.99 one-time (non-consumable):** `com.snail3d.mascii.unlock`

> Note: iOS in-app purchases must go through StoreKit (App Store Review 3.1.1),
> so Stripe cannot take an in-app payment. Stripe credentials remain useful for a
> future web companion (e.g. mascii.ai where the same pipeline runs in the browser).
> The product must be created in App Store Connect before testing the paywall.

## Build

```bash
xcodegen generate
xcodebuild -project Mascii.xcodeproj -scheme Mascii \
  -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
```

Requires: Xcode 26+, iOS 26.0 deployment target, xcodegen.

## Known limitations

- iOS suspends background app work: overnight renders need the screen on
  (UI shows a "keep the light on" note). Background modes for arbitrary
  durations are not allowed by App Store Review.
- 1080×1920 output is portrait-first; landscape source is pillarboxed into
  the cell grid.

## Roadmap

- [ ] Landscape / 1080×1920 ↔ 1920×1080 output
- [ ] More palettes (amber phosphor, green terminal, duotone)
- [ ] Cell-density control (crisper ↔ coarser)
- [ ] Share sheet for rendered MP4
- [ ] Web companion (mascii.ai) with Stripe checkout + same shader in WebGL
