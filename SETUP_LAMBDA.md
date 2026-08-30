# Lambda + EventBridge Scheduler セットアップ手順

GitHub Actionsの代わりにAWS Lambdaで毎時データ取得を行う構成。
スケジュールの遅延・スキップ・60日制限・実行保証の問題がすべて解消される。

TableauPublicDataExtractと同じ構成なので、既にそちらを設定済みなら
ECR・IAM・Schedulerの操作手順は同じ流れになる。

## なぜ切り替えるか

GitHub Actionsの `schedule` は公式にベストエフォートで、実行保証がない。
このリポジトリでは実測で以下のように悪化していた:

| 期間 | 実行数 | 成功率 |
|---|---|---|
| 〜2026/8/26 | 24時間で22回 | 約92% |
| 2026/8/26以降 | 59時間で8回 | 約14% |

cron構文・ブランチ・ワークフローの状態はいずれも正常で、GitHub側が
ワークフロー実行そのものを作成していなかった（実行番号に欠番なし）。

## 構成

```
EventBridge Scheduler（毎時0分、確実に実行）
  → Lambda関数（コンテナイメージ）
    → YouTube Data API v3
      → S3（metrics / attributes Parquet）
```

## 費用

| 項目 | 月額 |
|---|---|
| Lambda（730回 × 約60秒 × 512MB） | 無料枠内（0円） |
| EventBridge Scheduler | 0.1円未満 |
| ECR（コンテナイメージ保存） | 無料枠500MBまで0円 |
| **合計** | **ほぼ0円** |

---

## ステップ1：ECRリポジトリを作る

1. [ECRコンソール](https://ap-northeast-1.console.aws.amazon.com/ecr/repositories) を開く
2. 「**リポジトリを作成**」
   - 可視性: プライベート
   - リポジトリ名: `youtube-data-extractor`
3. 作成後、リポジトリのURIをコピーしておく
   - 形式: `<ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/youtube-data-extractor`

---

## ステップ2：Dockerイメージをビルドして ECR にプッシュ

ターミナルで以下を実行（`<ACCOUNT_ID>` は自分のAWSアカウントIDに置き換え）。

```bash
# AWSにDockerログイン
aws ecr get-login-password --region ap-northeast-1 \
  | docker login --username AWS \
    --password-stdin <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com

# イメージをビルド（M1/M2 MacはARM64ネイティブビルドで高速）
cd /path/to/YouTubeDataExtractor
docker build --platform linux/arm64 -t youtube-data-extractor .

# タグ付けしてプッシュ
docker tag youtube-data-extractor:latest \
  <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/youtube-data-extractor:latest
docker push \
  <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/youtube-data-extractor:latest
```

Windows等でx86_64ビルドする場合は `--platform linux/amd64` にして、
ステップ4のアーキテクチャも `x86_64` を選ぶこと（ビルドとLambdaの
アーキテクチャが食い違うと起動時に `exec format error` になる）。

> `data/` は `.dockerignore` で除外済み。除外しないと1.7GB超の
> ビルドコンテキスト転送だけで数分かかるので、削除しないこと。

---

## ステップ3：Lambda用IAMロールを作る

GitHub Actions用のOIDCロールとは**別のロールが必要**（信頼されたエンティティが
GitHubではなくLambdaサービスになるため）。

1. [IAMコンソール](https://console.aws.amazon.com/iam/) → ロール → 「ロールを作成」
2. **信頼されたエンティティ**: `AWS のサービス` → `Lambda`
3. **許可ポリシーをアタッチ**:
   - `AWSLambdaBasicExecutionRole`（CloudWatch Logsへの書き込み）
   - S3書き込み用のポリシー（下記。既存の同等ポリシーがあれば流用可）

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:GetObject"],
    "Resource": "arn:aws:s3:::<バケット名>/youtube_stats/*"
  }]
}
```

4. **ロール名**: `lambda-youtube-data`

---

## ステップ4：Lambda関数を作る

1. [Lambdaコンソール](https://ap-northeast-1.console.aws.amazon.com/lambda/) → 「関数の作成」
2. **コンテナイメージ**を選択
3. 設定:
   - **関数名**: `youtube-data-extractor`
   - **コンテナイメージURI**: ステップ1のECR URI + `:latest`
     （「イメージを参照」ボタンから選べる）
   - **アーキテクチャ**: `arm64`（ステップ2でarm64でビルドした場合）
4. 「関数の作成」後、設定タブで以下を変更:
   - **タイムアウト**: 5分（デフォルト3秒から変更）
   - **メモリ**: 512MB
   - **実行ロール**: `lambda-youtube-data`
5. **環境変数**を追加（設定 → 環境変数）:

   | キー | 値 | 必須 |
   |---|---|---|
   | `YOUTUBE_API_KEY` | YouTube Data API v3のAPIキー | 必須 |
   | `YOUTUBE_CHANNEL_ID` | 対象のチャンネルID | 必須 |
   | `S3_BUCKET` | バケット名 | 必須 |
   | `S3_PREFIX` | `youtube_stats` | 任意（未設定でも同じ既定値） |

   - `AWS_REGION` はLambdaランタイムが自動設定する予約変数なので**設定不要**
   - `S3_BUCKET` を設定し忘れるとCSV書き出しの分岐に入り、Lambdaの
     読み取り専用ファイルシステムでエラーになる

> **APIキーの扱い**: Lambdaの環境変数はAWS管理キーで保存時に暗号化される。
> 個人プロジェクトならこれで十分。より厳格に管理したい場合は
> AWS Secrets Manager（$0.40/シークレット/月）に置き、起動時に取得する
> コードを追加する方法もある。

---

## ステップ5：テスト実行

1. Lambdaコンソール → 「テスト」タブ
2. イベントJSON はデフォルトの `{}` のままでOK
3. 「テスト」をクリック
4. ログに `metrics: 4xx行をアップロードしました` が出れば成功

初回は属性が全件「変更あり」として記録される場合があるが、
2回目以降は `attributes: 変更なし` になるのが正常。

---

## ステップ6：EventBridge Schedulerで毎時実行

1. [EventBridge Scheduler コンソール](https://ap-northeast-1.console.aws.amazon.com/scheduler/home) を開く
2. 「スケジュールを作成」
3. **スケジュールパターン**:
   - 定期的なスケジュール → cron式
   - `0 * * * ? *`（毎時0分、UTC）
   - フレキシブルな時間枠: 無効（確実に0分に実行したい場合）
4. **ターゲット**:
   - AWS Lambda → `youtube-data-extractor`
5. 「スケジュールを作成」

---

## ステップ7：動作確認

1〜2時間おいてから、以下を確認する。

```sql
-- Athenaで最新スナップショットが直近1時間以内になっているか
SELECT max(snapshot_ts) FROM youtube_stats.metrics;
```

S3の `youtube_stats/metrics/year=YYYY/month=MM/` に毎時のParquetが
増えていればOK。

---

## ステップ8：GitHub Actionsのスケジュールを止める

Lambdaが安定して動き始めたら、GitHub Actionsのcronは不要。
`.github/workflows/fetch_youtube_stats.yml` から `schedule:` ブロックを
削除するPRを用意してあるので、それをマージする。

`workflow_dispatch`（手動実行）は残してあるので、Actionsタブからいつでも
手動でデータ取得を実行できる。

---

## イメージ更新手順（コード変更時）

`youtube_stats_extractor.py` や `s3_store.py` を変更したら、イメージを
作り直してLambdaに反映する必要がある。

```bash
docker build --platform linux/arm64 -t youtube-data-extractor .
docker tag youtube-data-extractor:latest \
  <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/youtube-data-extractor:latest
docker push \
  <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/youtube-data-extractor:latest

# Lambdaに最新イメージを反映
aws lambda update-function-code \
  --function-name youtube-data-extractor \
  --image-uri <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/youtube-data-extractor:latest \
  --region ap-northeast-1
```

---

## トラブルシューティング

| 症状 | 原因と対処 |
|---|---|
| `exec format error` | ビルドしたアーキテクチャとLambdaの設定が不一致。ステップ2と4を揃える |
| `Read-only file system: 'data'` | `S3_BUCKET` が未設定。環境変数を確認 |
| `AccessDenied` (S3) | 実行ロールのポリシーのResourceが `.../youtube_stats/*` になっているか確認 |
| `Task timed out` | タイムアウトが3秒のまま。5分に変更する |
| `quotaExceeded` | YouTube APIの1日10,000ユニット上限。毎時実行なら1日約480ユニットなので通常は起きない |
