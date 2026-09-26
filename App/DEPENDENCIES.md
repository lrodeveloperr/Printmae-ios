# UI dependency and reuse decision

| Role | Component | Commercial-use basis |
| --- | --- | --- |
| App layout, adaptive navigation, surfaces and buttons | GoodUse SwiftUI shell pinned in `project.yml` | WorksBien-owned source; no third-party template license |
| File selection | SwiftUI `fileImporter` and UniformTypeIdentifiers | Apple platform API |
| PDF page display | PDFKit, Quartz, and SwiftUI | Apple platform APIs; no third-party PDF editor package |
| Handoff | System `UIActivityViewController` | Apple platform API |
| Purchase | StoreKit 2 via the existing PrintMae engine | Apple platform API |
| Interface icons | SF Symbols in toolbars and rows; custom bundled app icon | Apple platform icon use; SF Symbols are never used as the app icon |

No copied marketplace template, remotely loaded design assets, font package,
advertising SDK, or additional commercial dependency is included. The browser
preview is a visual illustration, not an app runtime.

The host is a candidate pending Xcode compilation and iPhone/iPad device QA.
