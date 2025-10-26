# YouTube Data Extractor

YouTubeチャンネルの動画統計情報を取得するPythonプログラムです。
GitHub Actionsで定期実行し、データをリポジトリに自動保存できます。

## 機能

- 指定したYouTubeチャンネルの全動画の統計情報を取得
- 取得できる情報：
  - 動画ID
  - タイトル
  - 公開日
  - 視聴回数
  - いいね数
  - コメント数
  - 動画の長さ
  - 説明文
  - サムネイルURL
  - 動画URL
- データをタイムスタンプ付きCSVファイルで保存
- 基本統計情報の表示（総視聴回数、平均視聴回数など）
- 人気動画トップ5の表示
- **GitHub Actionsで毎日自動実行**
- **データをGitHubリポジトリに自動保存**

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

- **自動実行**: 毎日午前9時（UTC）= 日本時間18時に自動実行
- **手動実行**: `Actions` タブから `Fetch YouTube Statistics` を選択し、`Run workflow` で手動実行可能

### 4. データの保存場所

取得したデータは `data/` ディレクトリに保存されます：

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
総視聴回数: 1,234,567回
平均視聴回数: 8,230回
総いいね数: 45,678件
総コメント数: 12,345件

=== 最も視聴された動画 トップ5 ===
動画タイトル1... - 50,000回視聴 (2024-01-15)
動画タイトル2... - 45,000回視聴 (2024-02-20)
...
```

## 出力ファイル

CSVファイルには以下のカラムが含まれます：

- `video_id`: 動画ID
- `title`: 動画タイトル
- `published_at`: 公開日時
- `view_count`: 視聴回数
- `like_count`: いいね数
- `comment_count`: コメント数
- `duration`: 動画の長さ（ISO 8601形式）
- `description`: 動画の説明文
- `thumbnail_url`: サムネイルURL
- `video_url`: 動画URL

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
