# PrintMae app icon QA

## Locked concept

A white document silhouette, visible print-margin frame, and one secondary verification mark on a flat indigo field. It communicates “document preflight” without implying direct printing, a copier connection, or affiliation with a convenience-store chain.

## Comparison set

Checked on the Japanese App Store on 2026-09-25:

- [かんたんnetprint](https://apps.apple.com/jp/app/id1552990335)
- [PrintSmash](https://apps.apple.com/jp/app/id551942662)
- [PDF余白調整](https://apps.apple.com/jp/app/id1450718650)
- [ぴたプリ](https://apps.apple.com/jp/app/id6476952497)

This is a four-app task/category cohort, not a chart-wide quantitative study. The chosen mark avoids retail-chain colors and marks, QR imagery, printer hardware, text, and layouts copied from any member of the cohort.

## Mechanical checks

- Master: 1024 × 1024 PNG, sRGB, opaque.
- Master colors: two flat colors; no transparency, baked corner radius, outer shadow, text, logo, or QR code.
- Safe-zone: primary silhouette remains inside the iOS mask previews.
- Small-size exports inspected at 128, 64, and 48 px.
- Light and dark surround previews included.
- Grayscale distinction: figure and ground have materially different luminance.
- Host-app action: copy `AppIcon.appiconset` into the asset catalog and select it as the iOS App Icon source.

## Files

- `../AppIcon.appiconset/AppIcon-1024.png` — production master.
- `AppIcon-128.png`, `AppIcon-64.png`, `AppIcon-48.png` — small-size QA.
- `iOS-mask-light.png`, `iOS-mask-dark.png` — mask/surround QA only; do not ship these as app icons.

The package contains an asset catalog but no app target. The existing host app must select the catalog; this package does not install an icon by itself.
