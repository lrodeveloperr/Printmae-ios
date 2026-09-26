# PrintMae 1.0 — App Store Connect declaration evidence

Reviewed 2026-09-26. This is a decision record for the Japanese-only iOS listing. The age and content-rights answers are saved in App Store Connect; App Privacy is published as Data Not Collected. Recheck against the signed build before App Review.

## Age rating answer map

| Apple questionnaire | Proposed answer | Evidence |
| --- | --- | --- |
| Parental Controls; Age Assurance | No; No | No account, age gate, child access control, or age API in app/engine source. |
| Unrestricted Web Access | No | No embedded browser; Settings links open external privacy/help pages. |
| User-Generated Content | No | User documents are imported locally and never broadly distributed by the app. A user may explicitly invoke the system share sheet for an exported PDF. Apple defines this field by broad distribution as an intended app experience. |
| Social Media; Social Media Disabled for Users Under 13; Messaging and Chat | No; No; No | No feed, posting, other-user discovery, or in-app communication. |
| Advertising | No | Shell ad rail disabled; no advertising SDK or ad content. |
| Mature Themes; Medical or Wellness; Sexuality or Nudity; Violence; Chance-Based Activities | Never for every descriptor | The built-in two-page sample is generated from CoreGraphics; no third-party feed or developer-supplied media/content in these categories. Arbitrary user-selected local documents are not the app's supplied content. |
| Override to Higher Age Rating | None | Let Apple calculate the rating from the answers. |

Evidence: `App/PrintMaeApp.swift`, `App/PrintMaeModel.swift`, `App/Resources/ShellConfig.json`, `Engine/Sources/PrintMaeEngine/SampleDocumentFactory.swift`, and `App/DEPENDENCIES.md`. Apple age definitions: https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/

## Content Rights

**Proposed answer: No third-party content supplied or accessed by the app.** The app makes its own sample PDF, accepts files selected by the user, processes them on device, and uses the system share sheet only when the user chooses to export. Its print profiles contain factual format constraints and source URLs, but no embedded third-party article, image, media catalog, or connected service. The Japanese terms place responsibility for rights in user-selected documents on the user. The listing states that the app is independent of print providers.

Interpretation: the content-rights declaration concerns third-party material supplied or accessed as part of the app offering. The locally generated sample, local profiles, and user-selected files do not constitute a developer-provided catalog or a third-party content service. The app cannot verify ownership of every document selected by a user; its terms require users to hold rights to the documents they process. This is the basis for “No” in the current app, with the final signed build still subject to verification. Apple reference: https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/ and guideline 5.2: https://developer.apple.com/app-store/review/guidelines/

## App Privacy

**Published in App Store Connect on 2026-09-26:** Data Not Collected; Japanese privacy URL `https://lrodeveloperr.github.io/Printmae-ios/privacy/`. Publication was verified after reloading the page.

Evidence: `App/Resources/PrivacyInfo.xcprivacy` declares no tracking and no collected data. App/engine source has no account, analytics/ads SDK, document upload, network client, or embedded web view. Documents and analysis remain local; explicit iOS sharing goes to a user-selected destination. `StoreKit 2` handles purchase and the app locally records entitlement/export count. The linked GoodUseShell at pinned revision `6de35c55` is WorksBien-owned, has no external package dependencies in `Package.swift`, and its seven Swift source files contain no network, analytics, or advertising client. The app disables its ad rail.

Apple defines collection as data transmitted off-device for developer/partner access beyond real-time servicing: https://developer.apple.com/app-store/app-privacy-details/. The account holder approved and accepted the final Publish dialog, which attests that the responses are accurate and comply with guidelines and law and will be updated if practices change. The source-level answer is “Data Not Collected” on the current app and linked shell; verify the signed app and its dependencies before release and update this record if the final binary differs.

## Code → policy → listing reconciliation

| Claim | Source evidence | Public policy | Japanese listing and reviewer notes | Result |
| --- | --- | --- | --- | --- |
| Local document handling | `LocalDocumentImporter`, `PrintPreparationEngine`, `FileJobRepository` stage, analyze, render, and retain locally; no upload client | Processing and copies on device | On-device processing | Aligned |
| User-directed sharing | `UIActivityViewController` receives verified local URLs only after `openShare()` | Explicit recipient choice through iOS share | Explicit iOS destination selection; wording clarified 2026-09-26 | Aligned |
| Data/ads/tracking | Privacy manifest declares no collection/tracking; app and shell have no analytics/ad SDK; ad rail disabled | No developer collection, ads, tracking, analytics, location | Same | Aligned at source level |
| Purchase | Keychain ledger starts with three exports; StoreKit non-consumable lifetime product ID matches listing | Apple handles purchases, one-time Pro | Three free exports, lifetime Pro, App Store display price | Aligned |
| Content and rights | Sample PDF generated locally; no feed/content service; profile URLs are citations, not fetched content | Users responsible for document rights | Independent utility; no direct printer control | Aligned under interpretation above |
| Age content | No account, browser, social or messaging; built-in sample has no mature content | No contrary claim | Utility description | No contrary content in app-supplied material |

The former absolute “no document upload” phrasing was clarified across the policy, marketing page, Japanese listing, reviewer notes, and canonical product contract: the app does not upload a document for processing, while iOS sharing can send it to a user-selected recipient. Source-level consistency does not prove the final binary or all possible user-imported documents.

## Current gates

- The first macOS CI build failed because the runner could not access the private GoodUseShell repository; there is no signed final binary to audit yet.
- Age rating (4+) and Content Rights (No) were saved and verified after reloading App Store Connect on 2026-09-26. Their basis is the code, policy, and listing reconciliation above.
- App Privacy was published as Data Not Collected on 2026-09-26 following explicit account-holder approval of the final attestation. The published state was verified after reloading App Store Connect. Final-binary verification is still unavailable; no app version was submitted for review.
