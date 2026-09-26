# PrintMae 1.0 — App Store Connect declaration evidence

Reviewed 2026-09-26. This is a decision record for the Japanese-only iOS listing, not a claim that App Store Connect declarations have been submitted. Recheck against the signed build before App Review.

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

The App Store Connect question literally includes content an app “shows or accesses.” Because user-selected PDFs can be third-party works, the account holder should confirm this intended interpretation before declaring “No.” Selecting “Yes” would assert that the developer holds necessary rights to every such document, which cannot be established from the code. Apple reference: https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/ and guideline 5.2: https://developer.apple.com/app-store/review/guidelines/

## App Privacy

**Drafted in App Store Connect:** Data Not Collected; Japanese privacy URL `https://lrodeveloperr.github.io/Printmae-ios/privacy/`. **Not yet published.**

Evidence: `App/Resources/PrivacyInfo.xcprivacy` declares no tracking and no collected data. App/engine source has no account, analytics/ads SDK, document upload, network client, or embedded web view. Documents and analysis remain local; explicit iOS sharing goes to a user-selected destination. `StoreKit 2` handles purchase and the app locally records entitlement/export count. The linked GoodUseShell is WorksBien-owned and has no external package dependencies in its `Package.swift`; the app disables its ad rail.

Apple defines collection as data transmitted off-device for developer/partner access beyond real-time servicing: https://developer.apple.com/app-store/app-privacy-details/. The final Publish dialog asks the account holder to attest that the responses are accurate and comply with guidelines and law. Verify the signed app and its dependencies, then obtain the account holder's confirmation for that attestation. Update this record if the final binary differs.

## Current gates

- The first macOS CI build failed because the runner could not access the private GoodUseShell repository; there is no signed final binary to audit yet.
- Age rating and content rights are not saved in App Store Connect. Prior automatic approval review rejected blanket answers without verified facts; do not treat this proposed answer map as a submitted declaration.
- App Privacy is drafted but unpublished. No release submission has occurred.
