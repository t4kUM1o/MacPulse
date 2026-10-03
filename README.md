# MacPulse

macOSのメニューバーでCPU・GPU・本体ファンを監視するネイティブアプリです。macOS 13以降、Intel / Apple Silicon向けのUniversal Binaryとしてビルドできます。ファンや温度の取得・制御対応は機種によって異なります。

## 機能

- 固定幅のCPU・GPU使用率表示。初期値は1秒更新で、メニューを開いている間も更新。
- CPUの論理コア別使用率、CPU・GPUの履歴グラフ。
- GPU使用率、温度、クロック、VRAM使用量（ドライバーが公開している項目）。
- 本体ファンの現在・目標・最低・最高RPMをSMCから取得。
- 点をドラッグして編集できる温度カーブ。CPU / GPU / 高い方の温度を選択。
- 設定画面で表示項目・履歴・更新間隔を切り替え。設定は自動保存。
- 設定画面とカーブ編集画面にも実測ファンRPMを表示。
- ログイン時の自動起動、診断JSONの保存、情報のコピー。

## ダウンロード・起動

GitHub Releasesの `MacPulse.zip` を展開し、`MacPulse.app` をアプリケーションフォルダへ移動して起動します。初回起動でログイン時の自動起動登録を試みます。メニューから有効・無効を変更できます。

このビルドはローカルのアドホック署名です。Developer ID署名やAppleの公証は行っていません。

## ビルド

XcodeまたはCommand Line Tools（macOS 13以降のSDK）が必要です。

```sh
bash build.sh
```

`build/` にアプリ、`dist/` にZIPを生成します。

## ファンカーブ

メニューの「温度カーブを編集…」からグラフの点を動かし、「カーブを適用」を押します。SMC書き込みに必要な管理者認証はmacOSが行います。

%は**最大RPMに対する最低RPMの割合**です。元の最低RPMを下回らず、macOSが必要に応じてさらに回転数を上げられます。終了・温度取得失敗・通信途絶時には補助プロセスが元の最低RPMへ戻します。カーブの設定は保存されますが、起動時の自動適用はしません。

SMCの非公開インターフェースを使用しており、機種ごとの動作保証はありません。他のファン制御アプリとの同時使用は避けてください。GPUドライバーが返す0 RPMは、停止中か未報告かを区別できません。

詳しい操作は [ファンカーブ](fan-curve.txt) と [設定](settings.txt) を参照してください。

## ChatGPTUsage（別アプリ）

同時にビルドされる補助アプリです。残り使用量を**手動入力**してメニューバーに表示し、ChatGPTの利用量画面を開けます。ChatGPT / Codexの使用量を自動取得する機能は未実装です。初回表示は未入力の「—」で、メニューの「残り使用量を入力…」から設定します。

ChatGPTがこのMacにインストールされている場合、そのローカルアイコンを表示に使用します。リポジトリや配布ZIPにはOpenAIのアイコン素材を含めていません。非公式アプリです。

## 検証範囲

iMac18,3で本体ファン・CPU温度・AMD GPUの情報を実測しました。コア別使用率、固定幅表示、メニュー操作中の更新、カーブの補間、設定の切り替え、回転数表示を検証しています。Apple Siliconやその他の機種でのSMC制御は未検証です。

## 参考

- [smcFanControlのSMCプロトコル](https://github.com/hholtmann/smcFanControl/tree/master/smc-command)
- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
