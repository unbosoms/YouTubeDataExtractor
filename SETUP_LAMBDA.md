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

# ビルドしてそのままECRへプッシュ（M1/M2 MacはARM64ネイティブビルドで高速）
cd /path/to/YouTubeDataExtractor
docker buildx build \
  --platform linux/arm64 \
  --provenance=false \
  -t <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/youtube-data-extractor:latest \
  --push .
```

### `--provenance=false` は必須

これを付けないと、Lambda関数の作成時に次のエラーで失敗する。

```
The image manifest, config or layer media type for the source image ... is not supported.
```

Buildx v0.10以降は、プッシュ時に既定でビルドの来歴（provenance）情報を
添付マニフェストとして一緒に登録する。その結果、ECRには単一イメージではなく
**マニフェストリスト**（イメージ本体＋`unknown/unknown` プラットフォームの
アテステーション）が入り、Lambdaがこれを扱えずに拒否する。

**イメージを更新するたびに必要**なので、末尾の「イメージ更新手順」でも
同じオプションを付けること。

### アーキテクチャは必ずステップ4と揃える

Windows等でx86_64ビルドする場合は `--platform linux/amd64` にして、
ステップ4のアーキテクチャも `x86_64` を選ぶ。食い違うと、テスト実行時に
初期化が10ms程度で即死し、次のエラーになる。

```json
{"errorType": "Runtime.InvalidEntrypoint", "errorMessage": "... Error: ProcessSpawnFailed"}
```

> **重要**: コンテナイメージを使うLambda関数は、**作成後にアーキテクチャを
> 変更できない**。食い違った場合は、イメージ側を関数に合わせて再ビルドするか、
> 関数を削除して作り直すことになる。

### プッシュ後の確認

```bash
docker buildx imagetools inspect \
  <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/youtube-data-extractor:latest
```

- `Platform:` が意図したアーキテクチャ（`linux/arm64` など）になっていること
- `unknown/unknown` を含むマニフェストの一覧が出ないこと
  （出る場合は `--provenance=false` が効いていない）

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
   - **アーキテクチャ**: ステップ2でビルドしたものと同じ（`arm64` または `x86_64`）

   > **アーキテクチャは作成後に変更できない**（コンテナイメージの場合）。
   > ここを間違えると関数の作り直しになるので、ステップ2と必ず揃えること。

4. **実行ロール**（同じ作成画面の「デフォルトの実行ロールの変更」を展開）:
   - 「**既存のロールを使用する**」を選び、ステップ3で作った
     `lambda-youtube-data` を指定する

   > **ここが最もつまずきやすい**。既定の「新しいロールを基本的な Lambda
   > アクセス権限で作成」のまま進めると、CloudWatch Logs権限しか持たない
   > ロール（`youtube-data-extractor-role-xxxxxxxx` のような乱数付きの名前）が
   > 自動生成され、S3への書き込みで `AccessDenied` になる。
   > うっかり自動生成してしまった場合の復旧手順はトラブルシューティングを参照。

5. 「関数の作成」後、設定タブで以下を変更:
   - **タイムアウト**: 5分（デフォルト3秒から変更）
   - **メモリ**: 512MB（実測で使用量は約240MBなので十分）
6. **環境変数**を追加（設定 → 環境変数）:

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

### 初回実行で出る初期化タイムアウトについて

初回だけ、ログに次の行が出ることがある。

```
INIT_REPORT Init Duration: 9999.20 ms  Phase: init  Status: timeout
```

Lambdaの初期化フェーズには10秒の制限があり、**初回のコンテナイメージ展開**が
これを超えるために出る。Lambdaは初期化をやり直して処理を続行するので、
**失敗ではない**。2回目以降は1秒程度に収まる。

パッケージ読み込みが重いわけではないので、**メモリを増やす必要はない**。

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
# ビルドとプッシュ（--provenance=false を毎回付けること）
docker buildx build \
  --platform linux/arm64 \
  --provenance=false \
  -t <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/youtube-data-extractor:latest \
  --push .

# Lambdaに最新イメージを反映
aws lambda update-function-code \
  --function-name youtube-data-extractor \
  --image-uri <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/youtube-data-extractor:latest \
  --region ap-northeast-1
```

`--platform` は関数作成時に選んだアーキテクチャと必ず同じにすること
（後から関数側は変更できない）。

---

## トラブルシューティング

| 症状 | 原因と対処 |
|---|---|
| `The image manifest, config or layer media type ... is not supported`（関数作成時） | ビルド時に `--provenance=false` を付け忘れている。ステップ2のコマンドで再ビルド・再プッシュする |
| `Runtime.InvalidEntrypoint` / `ProcessSpawnFailed`（初期化が10ms程度で即死） | イメージとLambdaのアーキテクチャが不一致。下記「アーキテクチャ不一致の復旧」を参照 |
| `AccessDenied` (`s3:PutObject`) | 実行ロールにS3権限がない。下記「S3権限の後付け」を参照 |
| `YOUTUBE_API_KEYが設定されていません` | Lambdaの環境変数が未設定。ステップ4-6で3つ（`YOUTUBE_API_KEY` / `YOUTUBE_CHANNEL_ID` / `S3_BUCKET`）を設定する |
| `Read-only file system: 'data'` | `S3_BUCKET` が未設定でCSV書き出しの分岐に入っている。環境変数を確認 |
| `INIT_REPORT ... Status: timeout` | 初回のイメージ展開によるもので**異常ではない**。ステップ5の説明を参照 |
| `Task timed out` | タイムアウトが3秒のまま。5分に変更する |
| `チャンネルID xxx が見つかりません` | `YOUTUBE_CHANNEL_ID` に `@ハンドル` を入れている。`UC` で始まる24文字のIDが必要 |
| `quotaExceeded` | YouTube APIの1日10,000ユニット上限。毎時実行なら1日約480ユニットなので通常は起きない |

### アーキテクチャ不一致の復旧

まず両方を確認する。

```bash
# Lambda関数側
aws lambda get-function-configuration \
  --function-name youtube-data-extractor \
  --region ap-northeast-1 --query 'Architectures'

# イメージ側
docker buildx imagetools inspect \
  <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/youtube-data-extractor:latest
```

**コンテナイメージのLambda関数は作成後にアーキテクチャを変更できない**ので、
対処は次のどちらかになる。

- **イメージを関数に合わせる**: ステップ2の `--platform` を関数側の値にして
  再ビルド・再プッシュし、`aws lambda update-function-code` で反映する（簡単）
- **関数を作り直す**: arm64にしたい場合など。関数を削除し、ステップ4から
  やり直す（環境変数とタイムアウトの再設定も必要）

### S3権限の後付け

関数作成時に実行ロールを自動生成してしまった場合、そのロールに直接
ポリシーを足せばよい（関数を作り直す必要はない）。

ロール名はエラーメッセージ中の `assumed-role/<ロール名>/...` で分かる。

```bash
aws iam put-role-policy \
  --role-name <自動生成されたロール名> \
  --policy-name youtube-s3-write \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::<バケット名>/youtube_stats/*"
    }]
  }'
```

`GetObject` も必須。変更検知用のステートファイル
（`state/latest_attribute_hashes.parquet`）を毎回読むため、`PutObject` だけだと
次の行で同じエラーになる。反映は数秒なので、すぐテストを再実行してよい。
