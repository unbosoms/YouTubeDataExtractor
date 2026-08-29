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

-- 日毎の各動画の指標（その日の最後のスナップショット値）
-- 毎時実行のスナップショットから1日1行に集約する。実行時刻のばらつきや
-- スキップがあっても、その日に1回でも成功していれば正しく集計される
CREATE OR REPLACE VIEW youtube_stats.daily_metrics AS
SELECT
  video_id,
  date(snapshot_ts) AS dt,
  max_by(view_count, snapshot_ts)    AS view_count,
  max_by(like_count, snapshot_ts)    AS like_count,
  max_by(comment_count, snapshot_ts) AS comment_count
FROM youtube_stats.metrics
GROUP BY video_id, date(snapshot_ts);

-- 日毎の増分（前日比）
-- 注意:
-- - 各動画のデータ取得初日は比較相手がないため増分はNULLになる
-- - 丸1日欠測があった場合、翌日の増分に複数日分が乗る
CREATE OR REPLACE VIEW youtube_stats.daily_metrics_diff AS
SELECT
  video_id,
  dt,
  view_count,
  like_count,
  comment_count,
  view_count    - lag(view_count)    OVER (PARTITION BY video_id ORDER BY dt) AS daily_views,
  like_count    - lag(like_count)    OVER (PARTITION BY video_id ORDER BY dt) AS daily_likes,
  comment_count - lag(comment_count) OVER (PARTITION BY video_id ORDER BY dt) AS daily_comments
FROM youtube_stats.daily_metrics;

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
--
-- 直近7日間で最も伸びた動画
--   SELECT video_id, dt, daily_views, daily_likes
--   FROM youtube_stats.daily_metrics_diff
--   WHERE dt >= current_date - interval '7' day
--   ORDER BY daily_views DESC LIMIT 10;
