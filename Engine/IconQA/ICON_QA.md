# PrintMae app icon QA

## Selected concept

A dark-indigo document silhouette sits inside bold print-alignment brackets on an opaque warm-white field. Four small vermilion registration marks support the safe-area idea. It communicates “check the page before printing” without suggesting that PrintMae controls a copier or belongs to a convenience-store chain. This is the user-selected second concept from 2026-09-26.

## Comparison set

Checked visually on the Japanese App Store on 2026-09-26:

- [かんたんnetprint](https://apps.apple.com/jp/app/id1552990335)
- [PrintSmash](https://apps.apple.com/jp/app/id551942662)
- [PDF余白調整](https://apps.apple.com/jp/app/id1450718650)
- [ぴたプリ](https://apps.apple.com/jp/app/id6476952497)
- [netprint](https://apps.apple.com/jp/app/id1552990358)
- [コンビニフォト！](https://apps.apple.com/jp/app/id1514324432)

This is a six-app task/category cohort, not a chart-wide quantitative study or evidence that a particular icon style caused popularity. The official netprint pair uses text, store branding, and a copier diagram; PrintSmash uses a copier and wireless symbol; ぴたプリ uses a printer; PDF余白調整 combines arrows and text; コンビニフォト！ is type-led. The selected mark differentiates PrintMae as a preflight tool and avoids retail marks, QR imagery, printer hardware, and copied layouts.

## Mechanical checks

- Master: 1024 × 1024 PNG, sRGB, opaque.
- Visual palette: warm white, indigo, vermilion. Antialiased edges create additional pixel shades; there is no alpha channel, baked corner radius, outer shadow, text, logo, or QR code.
- Safe-zone: primary silhouette remains inside the iOS mask previews.
- Small-size exports inspected at 128, 64, and 48 px.
- Light and dark surround previews included.
- Grayscale distinction: indigo figure and warm-white ground have materially different luminance. The vermilion marks are secondary and not required to read the silhouette.
- `project.yml` selects `AppIcon` as the iOS asset-catalog icon source.

## Files

- `../AppIcon.appiconset/AppIcon-1024.png` — production master.
- `AppIcon-128.png`, `AppIcon-64.png`, `AppIcon-48.png` — small-size QA.
- `iOS-mask-light.png`, `iOS-mask-dark.png` — mask/surround QA only; do not ship these as app icons.

The production app also carries an identical master at `../../App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`. The host app selects that asset catalog as its iOS icon. The rounded mask previews are approximations for QA; the system applies the final shape.
