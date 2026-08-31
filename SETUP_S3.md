# S3 + Parquet + Athena 移行セットアップ手順

データ保存を「GitリポジトリへのCSVコミット」から「S3へのParquet追記」に
切り替えるための手順。TableauPublicDataExtract と同じ構成。
完了すると Tableau Cloud/Server から Athena コネクタで直接データに接続できる。

## データ構成

```
s3://<バケット>/youtube_stats/
├── metrics/year=YYYY/month=MM/*.parquet   指標の時系列（実行ごとに追記）
├── attributes/*.parquet                   属性の変更履歴（変更時のみ追記）
└── state/latest_attribute_hashes.parquet  変更検知用の内部ステート
```

- **metrics**: 視聴回数・いいね数・コメント数の実行ごとの値
- **attributes**: タイトル・説明文・動画の長さ等。変更があったときだけ
  新しい行が増える（SCD2方式）。タイトルや説明文の変更履歴もここで追える

## 1. AWS側の準備

### S3バケット作成

```bash
aws s3 mb s3://<バケット名> --region ap-northeast-1
```

### GitHub Actions用のIAMロール（OIDC・推奨）

アクセスキーをSecretsに置かずに済むOIDC連携を推奨。
TableauPublicDataExtract で作成済みのIDプロバイダ・ロールがあれば、
信頼ポリシーの `sub` 条件にこのリポジトリを追加するだけでよい。

1. IAMコンソール → IDプロバイダ → `token.actions.githubusercontent.com` を追加
   （audience: `sts.amazonaws.com`）※既にあればスキップ
2. IAMロールを作成し、信頼ポリシーに以下を設定:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<アカウントID>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:unbosoms/YouTubeDataExtractor:*"
      }
    }
  }]
}
```

3. ロールに以下の権限ポリシーをアタッチ:

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

## 2. GitHubリポジトリの設定

このリポジトリは「Env」というEnvironmentのSecretsを使用しているため、
Secretは Settings → Environments → Env に、Variableは
Settings → Secrets and variables → Actions → Variables に設定する:

| 種別 | 名前 | 値 |
|---|---|---|
| Variable | `S3_BUCKET` | バケット名 |
| Variable | `AWS_REGION` | `ap-northeast-1`（省略可） |
| Variable | `S3_PREFIX` | `youtube_stats`（省略可） |
| Secret（Env環境） | `AWS_ROLE_ARN` | 手順1で作ったロールのARN |

**`S3_BUCKET` を設定するまでは従来どおりCSVがGitにコミットされる**
（安全に切り替えられるようフォールバックになっている）。

## 3. 過去データの一括移行（1回限り）

Actionsタブ → 「Migrate historical CSVs to S3」 → Run workflow

`data/` の全CSVスナップショットが metrics（月別Parquet）と
attributes（変更履歴）に変換されてS3にアップロードされる。

ローカルで試す場合（S3に書かず `_local_s3/` に出力するドライラン）:

```bash
python migrate_to_s3.py
```

## 4. Athenaテーブル作成

`athena_ddl.sql` の `<YOUR_BUCKET>` をバケット名に置き換えて
Athenaのクエリエディタで実行（データベース作成＋テーブル2つ＋ビュー2つ）。

確認クエリ:

```sql
SELECT count(*) FROM youtube_stats.metrics;
SELECT max(snapshot_ts) FROM youtube_stats.metrics;
```

### 日次集計ビュー

`athena_ddl.sql` には日毎の分析用ビュー `daily_metrics` も含まれている。
1日1行に集約した累積値と前日比の増分、さらに各動画の最新の属性
（タイトル・ショート/ライブ判定等）が入っているので、Tableauからは
このビュー単体でそのまま使える。

| 列 | 内容 |
|---|---|
| `view_count` / `like_count` / `comment_count` | その日の最終スナップショットの累積値。折れ線グラフ向き |
| `daily_views` / `daily_likes` / `daily_comments` | 前日比の増分。「その日に何回見られたか」なので棒グラフ向き |
| `title` / `is_short` / `is_live_broadcast` / `published_at` / `video_url` | 各動画の最新の属性 |
| `last_snapshot_ts` / `prev_snapshot_ts` | その日・前日の最終スナップショット時刻 |
| `hours_since_prev` | 上記2つの差（時間）。増分が実際に何時間ぶんなのかを表す |

日中の複数スナップショットからは**その日の最終値**を採る。いいね・コメントは
取り消しや削除で減ることがあるため、最大値ではなく最終値を使っている
（視聴回数は単調増加なのでどちらでも同じ）。

増分は**前の行がちょうど前日のときだけ**計算し、それ以外は `NULL` になる。
したがって次の行は `NULL` になる:

- 各動画のデータ取得初日（比較相手がないため）
- 丸1日データが欠けた日の翌日（複数日分が合算されるのを防ぐため）

集計するときは `WHERE daily_views IS NOT NULL` で除外するとよい。

### 増分が24時間ぶんとは限らない点への対処

「前日」であっても、増分がちょうど24時間ぶんとは限らない。前日の最終取得が
23:00、当日の最終取得が09:00なら、`daily_views` は10時間ぶんの増分になる。

これを見分けられるよう `hours_since_prev`（実測の経過時間）を持たせている。
Tableau側で `hours_since_prev < 23` のときに警告を出す、といった使い方を想定。

値は実測のままにしてあるので、24時間換算が必要ならTableau側の計算フィールドで
`daily_views * 24 / hours_since_prev` のように求める。

> **旧構成からの移行**: 以前は `daily_metrics` と `daily_metrics_diff` の
> 2ビュー構成だった。増分を `daily_metrics` に統合したので
> `daily_metrics_diff` は不要になり、`athena_ddl.sql` の冒頭で
> `DROP VIEW IF EXISTS` している。

## 5. Tableau Cloud/Server から接続

1. データソース → コネクタ → **Amazon Athena**
2. サーバー: `athena.ap-northeast-1.amazonaws.com`、ポート: `443`
3. S3ステージングディレクトリ: `s3://<バケット名>/athena-results/`
   （Athenaのクエリ結果用。バケット設定のクエリ結果ロケーションと合わせる）
4. 認証: Athena/S3の読み取り権限を持つIAMアクセスキー
5. データベース `youtube_stats` の **`daily_metrics`** を選ぶ

日単位の分析は `daily_metrics` 単体で完結する（タイトル・動画種別まで
結合済みなので、追加のJOINは不要）。時間単位の細かい推移を見たい場合だけ、
`metrics` に `attributes` の各動画最新行（`athena_ddl.sql` 末尾のクエリ例参照）
をJOINして使う。

## 6. （任意）リポジトリの軽量化

S3移行が安定したら `data/` フォルダは不要になる。ただしGit履歴に
過去データが残るため、リポジトリ自体を軽くするには履歴の書き換え
（`git filter-repo` 等）が必要。実施する場合は別途相談。
