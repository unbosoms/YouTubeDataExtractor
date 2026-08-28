-- Athenaで1回だけ実行するDDL。
-- <YOUR_BUCKET> を実際のS3バケット名に置き換えてから実行してください。
-- （S3_PREFIXを変更している場合は youtube_stats の部分も合わせて変更）

CREATE DATABASE IF NOT EXISTS youtube_stats;

-- 指標の時系列（実行ごとに1スナップショット分が追記される）
CREATE EXTERNAL TABLE youtube_stats.metrics (
  snapshot_ts    timestamp,
  video_id       string,
  view_count     bigint,
  like_count     bigint,
  comment_count  bigint
)
PARTITIONED BY (year string, month string)
STORED AS PARQUET
LOCATION 's3://<YOUR_BUCKET>/youtube_stats/metrics/'
TBLPROPERTIES (
  -- Partition Projection: パーティション追加クエリ(MSCK等)が不要になる
  'projection.enabled' = 'true',
  'projection.year.type' = 'integer',
  'projection.year.range' = '2025,2035',
  'projection.month.type' = 'integer',
  'projection.month.range' = '1,12',
  'projection.month.digits' = '2',
  'storage.location.template' =
    's3://<YOUR_BUCKET>/youtube_stats/metrics/year=${year}/month=${month}'
);

-- 動画属性の変更履歴（変更があった行だけが追記される / SCD2）
-- 各動画の時点tでの属性は effective_from <= t の最新行
CREATE EXTERNAL TABLE youtube_stats.attributes (
  effective_from         timestamp,
  description            string,
  duration               string,
  duration_seconds       string,
  has_shorts_hashtag     string,
  is_live_broadcast      string,
  is_short               string,
  live_broadcast_status  string,
  published_at           string,
  thumbnail_url          string,
  title                  string,
  video_id               string,
  video_url              string,
  row_hash               string
)
STORED AS PARQUET
LOCATION 's3://<YOUR_BUCKET>/youtube_stats/attributes/';

-- 動作確認クエリの例:
--
-- 最新スナップショットのview_count上位10件
--   SELECT video_id, view_count
--   FROM youtube_stats.metrics
--   WHERE snapshot_ts = (SELECT max(snapshot_ts) FROM youtube_stats.metrics)
--   ORDER BY view_count DESC LIMIT 10;
--
-- 各動画の最新属性（Tableauのデータソースに使う形）
--   SELECT *
--   FROM (
--     SELECT *, row_number() OVER (
--       PARTITION BY video_id ORDER BY effective_from DESC) AS rn
--     FROM youtube_stats.attributes
--   ) WHERE rn = 1;
