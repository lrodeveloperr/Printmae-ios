# プリント前 — App Store Connect 1.0

This is the Japanese release listing copy. English is only an optional in-app navigation language for the developer's testing. The Japanese version, App Review notes, and contact information are saved in App Store Connect. The version remains a draft until the native build and authentic screenshots are supplied.

| Field | Value |
| --- | --- |
| Primary language | Japanese |
| Name | プリント前｜コンビニ印刷PDFチェック |
| Subtitle | 余白・向き・サイズを自動で整える |
| Keywords | 余白設定,用紙サイズ,向き変更,履歴書,写真プリント,ファイル圧縮 |
| Primary / secondary category | Utilities / Productivity |
| App price and availability | Free; Japan |
| Release | Manual after approval |
| Support URL | https://worksbienstudios.com/customerservice |
| Marketing URL | https://lrodeveloperr.github.io/Printmae-ios/ |
| Privacy URL | https://lrodeveloperr.github.io/Printmae-ios/privacy/ |

## Description

コンビニでPDFを印刷する前に、余白・向き・用紙サイズ・ファイル容量を確認し、印刷しやすいPDFに整えるアプリです。

プリント前は、プリンターへ直接送るアプリではありません。書類をこの端末内で確認・調整し、完成した印刷用PDFを印刷アプリへ共有するか、「ファイル」に保存します。

■ 印刷前に確認
・ページの向きと用紙サイズ
・余白と印刷の安全範囲
・ページ数とファイル容量
・パスワード保護や読み込みエラー
・印刷方法ごとの主なファイル条件

■ 自動で整える
・A4またはB5へ比率を保って調整
・ページの回転
・白い余白の追加
・画像中心のPDFを圧縮
・上限を超えるPDFを分割
・写真を印刷用PDFに変換

■ 印刷前に見える
実際の用紙に近いプレビューで、文字や画像が端に寄りすぎていないか確認できます。元のファイルと仕上がりを切り替えて比較できます。

■ 安心して書き出し
作成したPDFをもう一度開いて、ページ数・用紙サイズ・容量を確認してから共有します。元のファイルは変更しません。

■ プライバシー
書類は端末内で処理されます。アカウント登録、広告、追跡、書類のアップロードはありません。

分析とプレビューは無料です。最初の3回は印刷用PDFを書き出して試せます。その後は、買い切りのプリント前 Proで回数制限なく書き出せます。購入価格はアプリ内に表示されるApp Storeの価格をご確認ください。

ご注意：本アプリはコンビニ各社やプリンターメーカーの公式アプリではありません。実際に印刷する前に、店頭のコピー機で最終プレビューと印刷設定を確認してください。

## In-app purchase

| Field | Value |
| --- | --- |
| Type | Non-consumable |
| Product ID | com.worksbien.printmae.pro.lifetime |
| Reference name | PrintMae Pro Lifetime |
| Japanese display name | プリント前 Pro（買い切り） |
| Japanese description | 印刷用PDFの書き出しを回数制限なく利用できます。 |
| Japan price | ¥980 |
| Availability | Japan |

## Authentic screenshot plan

Capture the released build with fictional documents on both iPhone and iPad. The first three iPhone images should show the actual analysis, paper preview, and verified export. Suggested Japanese captions:

1. コンビニで印刷する前に、PDFの問題を確認
2. 余白・向き・サイズをまとめて整える
3. 書き出し後も確認して、印刷アプリへ共有

Use a fictional document that genuinely triggers the displayed findings. The built-in two-page A4 sample is a clean file and should not be portrayed with warnings. Do not add proof rows or values absent from the actual UI.

## App Review notes

アカウント登録や専用ハードウェアは不要です。iPhoneとiPadに対応しています。

確認手順：
1. 「サンプルで試す」を選択し、PDFの分析結果を確認します。
2. 「用紙プレビューを見る」で用紙と安全範囲を確認します。
3. 「印刷用PDFを書き出す」から印刷方法を選び、書き出します。最初の3回は無料です。
4. iOSの共有シートで印刷アプリへの共有または「ファイル」に保存できます。

書類は端末内で処理されます。広告、追跡、解析SDK、書類のアップロード、位置情報の利用はありません。4回目以降の書き出しで買い切りのプリント前 Proが案内されます。

## Submission gates

- App Review contact and the corrected Japanese version copy are saved in App Store Connect. Keep personal contact details in App Store Connect rather than this public repository.
- The accidental English (U.S.) App Store version, name/subtitle, and Pro purchase localizations were removed. Japanese is the sole storefront localization; the Settings picker retains English only as an in-app navigation control for testing.
- No native iOS build or authentic iPhone/iPad screenshots have been uploaded. The purchase review screenshot must show the actual paywall.
- The first native GitHub Actions build cannot resolve the private `Swift-UI-shell-ios` package from the runner. Grant that workflow read access to the package repository before using its build result to capture screenshots.
- App privacy responses are entered but unpublished; the final Publish dialog asks the account holder to attest to accuracy and legal compliance. Confirm the final binary's data practices before publishing.
- Age rating and content rights responses require a verified submission declaration. Accessibility features require a native device audit before claiming support.
