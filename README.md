# TACT iOS

TACTの締切が近い未提出課題を、iPhoneの課題一覧とホーム画面ウィジェットで確認する試作です。

- 本人がアプリ内のTACT画面でサインインします。有効なTACTセッションを端末のKeychainで再利用します。
- ウィジェットは小サイズで1件、中サイズで最大3件を表示します。約1時間を目安にTACTに自動同期を試みます。WidgetKitが実行時刻を決めます。
- 同期に失敗しても前回の課題と最終同期時刻を表示します。再接続時は同じWebViewのデータストアを使います。
- 認証情報と課題データは端末に保存し、独自のサーバーを経由せずTACTに接続します。

## 起動

1. `TACT.xcodeproj` をXcodeで開きます。プロジェクトを再生成する場合は、XcodeGenを用意して `xcodegen generate` を実行します。
2. `TACT` と `TACTWidget` の両ターゲットで同じ署名チームを選びます。両ターゲットに App Group `group.jp.matsuokakoki.tact-ios` を割り当てます。別のグループを使う場合は `project.yml` のグループ設定と `TACTStore.group` を揃え、プロジェクトを再生成してください。
3. iOS 17以降のiPhoneで `TACT` スキームを実行し、「TACTに接続」を開きます。
4. iPhoneのホーム画面に「TACTの未提出課題」ウィジェットを追加します。

## 実機で確認すること

- 初回のTHERSログインから課題取得まで完了する。
- アプリを終了して開き直しても、有効なセッションで同期できる。
- 下書きは残り、TACTで提出した課題は同期後に消える。判定は提出日時または明示的な提出済みフラグを使う。
- アプリを閉じた状態でウィジェットの同期時刻が進む。TACTの期限切れ後も最後の課題が表示され、アプリで再接続できる。
- 期限切れ後の再接続で、パスワード再入力やMFAが必要になった回数を記録する。

## 参照実装

- [sakai-tasks-mcp](https://github.com/sayt25606-rgb/sakai-tasks-mcp) のWebViewログイン、Sakai API、セッション管理。
- [tact-extension](https://github.com/matsuokakoki/tact-extension) の課題取得、提出判定、キャッシュ。
