# YouTube Data Extractor

YouTubeチャンネルの動画統計情報を取得するPythonプログラムです。
AWS Lambda（推奨）またはGitHub Actionsで定期実行し、データをS3にParquet形式で
保存できます。

## 機能

- 指定したYouTubeチャンネルの全動画の統計情報を取得
- 取得できる情報：
  - 動画ID
  - タイトル
  - 公開日
  - 視聴回数
  - いいね数
  - コメント数
  - 動画の長さ（ISO 8601形式と秒数）
  - **ショート動画判定**（60秒以内 + #shortsハッシュタグで判定）
  - **ライブ配信判定**（ライブ配信アーカイブを自動検出）
  - ハッシュタグの有無
  - 説明文
  - サムネイルURL
  - 動画URL
- データをタイムスタンプ付きCSVファイルで保存
- **S3へのParquet形式保存に対応**（`S3_BUCKET`設定時。[SETUP_S3.md](SETUP_S3.md)参照）
- 基本統計情報の表示（総視聴回数、平均視聴回数など）
- **ショート動画、通常動画、ライブ配信の統計を個別に表示**
- 人気動画トップ5の表示（動画タイプも表示）
- **Lambda + EventBridge Schedulerで毎時自動実行**（[SETUP_LAMBDA.md](SETUP_LAMBDA.md)参照）
- **GitHub Actionsでの定期実行にも対応**

## 必要要件

- Python 3.7以上
- YouTube Data API v3のAPIキー

## セットアップ

### 1. リポジトリのクローン

```bash
git clone <repository-url>
cd YouTubeDataExtractor
```

### 2. 依存パッケージのインストール

```bash
pip install -r requirements.txt
```

### 3. YouTube Data API v3のAPIキーの取得

1. [Google Cloud Console](https://console.cloud.google.com/)にアクセス
2. 新しいプロジェクトを作成（または既存のプロジェクトを選択）
3. 「APIとサービス」→「ライブラリ」から「YouTube Data API v3」を有効化
4. 「APIとサービス」→「認証情報」からAPIキーを作成

### 4. 環境変数の設定

`.env.example`をコピーして`.env`ファイルを作成：

```bash
cp .env.example .env
```

`.env`ファイルを編集して、APIキーとチャンネルIDを設定：

```env
YOUTUBE_API_KEY=あなたのAPIキー
YOUTUBE_CHANNEL_ID=対象のチャンネルID
OUTPUT_FILE=youtube_stats.csv
```

#### チャンネルIDの確認方法

チャンネルIDは以下の方法で確認できます：

1. チャンネルページのURLから取得
   - `https://www.youtube.com/channel/UCxxxxxxxxxxxxxx` の `UCxxxxxxxxxxxxxx` 部分
2. カスタムURLの場合は、チャンネルページのソースコードから`channelId`を検索

## GitHub Actionsで自動実行する設定

GitHub Actionsを使用して、毎日自動でYouTube統計を取得し、リポジトリに保存できます。

### 1. GitHub Secretsの設定

**方法A: Environment Secrets（推奨）**

このリポジトリは「Env」というEnvironmentを使用する設定になっています：

1. GitHubリポジトリページで `Settings` → `Environments` に移動
2. 「Env」という名前のEnvironmentを選択（なければ作成）
3. `Add secret` をクリック
4. 以下の2つのSecretsを追加：

   - **Name**: `YOUTUBE_API_KEY`
     - **Value**: あなたのYouTube Data API v3のAPIキー

   - **Name**: `YOUTUBE_CHANNEL_ID`
     - **Value**: 対象のチャンネルID

**方法B: Repository Secrets**

または、リポジトリ全体で使用するSecretsとして設定する場合：

1. GitHubリポジトリページで `Settings` → `Secrets and variables` → `Actions` に移動
2. `New repository secret` をクリック
3. 上記と同じ2つのSecretsを追加
4. ワークフローファイル (`.github/workflows/fetch_youtube_stats.yml`) の `environment: Env` の行を削除またはコメントアウト

### 2. GitHub Actionsの有効化

- リポジトリの `Actions` タブで、ワークフローが有効になっていることを確認
- `Fetch YouTube Statistics` ワークフローが表示されるはずです

### 3. 実行スケジュール

定期実行の方式は2つあり、用途に応じて選べます。**両方を同時に有効にすると
同じ時間帯にデータが二重に記録される**ので、どちらか一方にしてください。

#### 構成A: 簡易構成（GitHubだけで完結）

AWSの設定なしで動かせます。お試しや小規模な用途向けです。

`.github/workflows/fetch_youtube_stats.yml` の `schedule:` はコメントアウトして
あるので、コメントを外すと有効になります。

```yaml
  schedule:
    - cron: '17 * * * *'
```

ただし**GitHubの `schedule` は公式にベストエフォートで、実行保証がありません**。
このリポジトリでの実測では、成功率が92%から14%まで低下したことがありました。
毎時きっちり動くことを期待しないでください。

#### 構成B: リッチ構成（S3 + Lambda）※推奨

AWS Lambda + EventBridge Schedulerが毎時確実に実行します。遅延・スキップは
起こりません。費用はほぼ0円です。

セットアップ手順は [SETUP_LAMBDA.md](SETUP_LAMBDA.md) を参照してください。
この構成では、ワークフローの `schedule:` はコメントアウトしたままにします。

#### 手動実行（どちらの構成でも共通）

`Actions` タブから `Fetch YouTube Statistics` を選択し、`Run workflow` で
いつでも手動実行できます。構成Bを使っている場合も、Lambdaに問題があったときの
予備手段として利用できます。

### 4. データの保存場所

**S3モード（推奨）**: リポジトリのVariableに `S3_BUCKET` を設定すると、
データはParquet形式でS3に保存されます（Gitへのコミットは行われません）：

- `s3://<バケット>/youtube_stats/metrics/year=YYYY/month=MM/*.parquet`: 指標（視聴回数等）の時系列
- `s3://<バケット>/youtube_stats/attributes/*.parquet`: 属性（タイトル・説明文等）の変更履歴（SCD2）

セットアップ手順（IAMロール・過去データ移行・Athenaテーブル作成）は
[SETUP_S3.md](SETUP_S3.md) を参照してください。

**CSVモード（従来・`S3_BUCKET`未設定時）**: 取得したデータは `data/` ディレクトリに保存されます：

- `data/youtube_stats_YYYYMMDD_HHMMSS.csv`: タイムスタンプ付きデータ（履歴）
- `data/youtube_stats_latest.csv`: 最新のデータ

データは自動的にコミット・プッシュされ、リポジトリに保存されます。

## 使い方

### ローカルで実行する場合

スクリプトを実行：

```bash
python youtube_stats_extractor.py
```

実行すると：

1. 指定したチャンネルの全動画情報を取得
2. 統計情報をタイムスタンプ付きCSVファイルとして`data/`ディレクトリに保存
3. コンソールに基本統計と人気動画トップ5を表示

## 出力例

```
チャンネルID UCxxxxxxxxxxxxxx の動画情報を取得中...
プレイリストID: UUxxxxxxxxxxxxxx
動画数: 150件
動画の詳細情報を取得中...

統計情報を data/youtube_stats_20250126_180000.csv に保存しました
最新データを data/youtube_stats_latest.csv に保存しました

=== 基本統計 ===
総動画数: 150件
  - ショート動画: 45件
  - ライブ配信（アーカイブ含む）: 10件
  - 通常動画: 95件
  - 60秒以内（ハッシュタグなし）: 3件

総視聴回数: 1,234,567回
  - ショート動画: 234,567回
  - ライブ配信: 150,000回
  - 通常動画: 850,000回

平均視聴回数: 8,230回
  - ショート動画: 5,212回
  - ライブ配信: 15,000回
  - 通常動画: 8,947回

総いいね数: 45,678件
総コメント数: 12,345件

=== 最も視聴された動画 トップ5 ===
[通常] 動画タイトル1... - 50,000回視聴 (2024-01-15)
[ショート] 動画タイトル2... - 45,000回視聴 (2024-02-20)
[ライブ] 動画タイトル3... - 40,000回視聴 (2024-03-10)
...
```

## 出力ファイル

CSVファイルには以下のカラムが含まれます：

- `video_id`: 動画ID
- `title`: 動画タイトル
- `published_at`: 動画の公開日時（YouTube上で公開された日時）
- `fetched_at`: データ取得日時（このプログラムでデータを取得した日時、ISO 8601形式）
- `view_count`: 視聴回数
- `like_count`: いいね数
- `comment_count`: コメント数
- `duration`: 動画の長さ（ISO 8601形式、例: PT1M30S = 1分30秒）
- `duration_seconds`: 動画の長さ（秒数）
- `has_shorts_hashtag`: #shortsハッシュタグの有無（True/False）
- `is_short`: ショート動画判定（True/False）
- `is_live_broadcast`: ライブ配信判定（True/False）
- `live_broadcast_status`: ライブ配信ステータス（none/live/upcoming/completed）
- `description`: 動画の説明文
- `thumbnail_url`: サムネイルURL
- `video_url`: 動画URL

**`fetched_at`フィールドの用途**:
- 毎日自動実行される際に、いつ取得したデータかを記録
- 時系列で視聴回数やいいね数の変化を追跡可能
- 同じ動画の異なる日時のデータを比較できる

### ショート動画の判定基準（保守的な判定）

このプログラムは、**60秒以内 AND #shortsハッシュタグあり** の両方を満たす動画のみをショート動画と判定します：

- ✅ `is_short = True`: 60秒以内 AND タイトルまたは説明文に `#shorts` または `#short` が含まれる
- ❌ `is_short = False`: 上記以外（60秒超、またはハッシュタグなし）

**60秒以内だがハッシュタグなしの動画について**:
- これらは `is_short = False` と判定されますが、統計表示時に「60秒以内（ハッシュタグなし）」として別途カウントされます
- CSVで `duration_seconds` と `has_shorts_hashtag` を確認することで、後から分析できます

### ライブ配信の判定基準

- `live_broadcast_status = "completed"`: 過去のライブ配信アーカイブ → `is_live_broadcast = True`
- `live_broadcast_status = "live"`: 現在配信中（通常は存在しない） → `is_live_broadcast = True`
- `live_broadcast_status = "upcoming"`: 配信予定 → `is_live_broadcast = True`
- `live_broadcast_status = "none"`: 通常の動画 → `is_live_broadcast = False`

## 注意事項

- YouTube Data API v3には1日あたりのクォータ制限があります（デフォルト: 10,000ユニット/日）
- このスクリプトは1回の実行で約50-100ユニット程度を消費します（動画数による）
- APIキーは絶対に公開しないでください
- `.env`ファイルは`.gitignore`に追加することを推奨します
- GitHub Actionsで実行する場合は、必ずGitHub Secretsを使用してAPIキーを保護してください
- データファイル（`data/`ディレクトリ）はリポジトリにコミットされるため、動画数が多い場合はリポジトリサイズが増加します

## トラブルシューティング

### APIキーが無効です

- APIキーが正しく設定されているか確認
- Google Cloud ConsoleでYouTube Data API v3が有効化されているか確認

### チャンネルIDが見つかりません

- チャンネルIDが正しいか確認
- カスタムURLの場合は、チャンネルページのソースから実際のチャンネルIDを確認

### クォータ超過エラー

- 翌日まで待つか、Google Cloud Consoleでクォータの引き上げをリクエスト

### GitHub Actionsが失敗する

#### "YOUTUBE_API_KEYが設定されていません" エラー

1. **Environment Secretsの設定を確認**（このリポジトリのデフォルト設定）:
   - リポジトリの `Settings` → `Environments` → `Env` に移動
   - `YOUTUBE_API_KEY` と `YOUTUBE_CHANNEL_ID` の両方が登録されているか確認
   - Secret名は**正確に一致**する必要があります（大文字小文字を含む）
   - Environmentの名前が「Env」であることを確認

2. **または、Repository Secretsの設定を確認**:
   - リポジトリの `Settings` → `Secrets and variables` → `Actions` に移動
   - こちらに設定する場合は、ワークフローファイルの `environment: Env` の行を削除する必要があります

3. **Secretの再設定**:
   - 既存のSecretを削除して再度追加してみる
   - 値にスペースや改行が含まれていないか確認

4. **ワークフローログを確認**:
   - `Actions` タブで失敗したワークフローを開く
   - "Check secrets configuration" ステップで何が表示されているか確認
   - ✅ が表示されていればSecretは正しく設定されています

#### その他のエラー

- リポジトリの`Actions`タブでエラーログを確認
- ワークフローに`contents: write`権限が付与されているか確認（設定済み）
- APIキーのクォータが超過していないか確認

### データがコミットされない

- GitHub Actionsのログを確認
- リポジトリのブランチ保護ルールを確認（保護されている場合はbotからのプッシュが制限される可能性）

## ライセンス

MIT License
