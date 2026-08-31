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

-- 旧構成（daily_metrics と daily_metrics_diff の2ビュー）からの移行用。
-- 増分は daily_metrics に統合したので daily_metrics_diff は不要。
-- 依存関係があるため、daily_metrics を作り直す前に削除しておく
DROP VIEW IF EXISTS youtube_stats.daily_metrics_diff;

-- 日毎の各動画の指標と前日比
--
-- 毎時のスナップショットを1日1行に集約し、前日からの増分を付ける。
-- 各動画の最新の属性（タイトル・種別等）も結合済みなので、Tableauからは
-- このビュー単体でそのまま使える。
--
-- 増分（daily_views / daily_likes / daily_comments）は、前の行が
-- 「ちょうど前日」のときだけ計算する。したがって以下はNULLになる:
-- - 各動画のデータ取得初日（比較相手がない）
-- - 丸1日データが欠けた日の翌日（複数日分が合算されるのを防ぐため）
--
-- 日付はJST基準（snapshot_ts をJSTのnaive timestampとして保存しているため）
CREATE OR REPLACE VIEW youtube_stats.daily_metrics AS
WITH
  daily AS (
    SELECT
      video_id,
      date(snapshot_ts) AS metric_date,
      -- その日の最終スナップショット値。いいね・コメントは取り消しや削除で
      -- 減ることがあるため、MAXではなく最終値を採る
      max_by(view_count, snapshot_ts)    AS view_count,
      max_by(like_count, snapshot_ts)    AS like_count,
      max_by(comment_count, snapshot_ts) AS comment_count
    FROM youtube_stats.metrics
    GROUP BY video_id, date(snapshot_ts)
  ),
  with_prev AS (
    SELECT
      video_id,
      metric_date,
      view_count,
      like_count,
      comment_count,
      lag(view_count)    OVER w AS prev_view_count,
      lag(like_count)    OVER w AS prev_like_count,
      lag(comment_count) OVER w AS prev_comment_count,
      lag(metric_date)   OVER w AS prev_date
    FROM daily
    WINDOW w AS (PARTITION BY video_id ORDER BY metric_date)
  ),
  latest_attrs AS (
    SELECT video_id, title, is_short, is_live_broadcast, published_at, video_url
    FROM (
      SELECT
        video_id, title, is_short, is_live_broadcast, published_at, video_url,
        row_number() OVER (PARTITION BY video_id ORDER BY effective_from DESC) AS rn
      FROM youtube_stats.attributes
    )
    WHERE rn = 1
  )
SELECT
  p.video_id,
  a.title,
  -- attributesは全列string型なので、Tableauで扱いやすいようbooleanに直す
  (a.is_short = 'True')          AS is_short,
  (a.is_live_broadcast = 'True') AS is_live_broadcast,
  a.published_at,
  a.video_url,
  p.metric_date,
  p.view_count,
  p.like_count,
  p.comment_count,
  CASE WHEN p.prev_date = date_add('day', -1, p.metric_date)
       THEN p.view_count - p.prev_view_count END       AS daily_views,
  CASE WHEN p.prev_date = date_add('day', -1, p.metric_date)
       THEN p.like_count - p.prev_like_count END       AS daily_likes,
  CASE WHEN p.prev_date = date_add('day', -1, p.metric_date)
       THEN p.comment_count - p.prev_comment_count END AS daily_comments
FROM with_prev p
LEFT JOIN latest_attrs a ON p.video_id = a.video_id;

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
-- （daily_views IS NOT NULL で、初日と欠測明けの行を除く）
--   SELECT title, metric_date, view_count, daily_views, daily_likes
--   FROM youtube_stats.daily_metrics
--   WHERE metric_date >= current_date - interval '7' day
--     AND daily_views IS NOT NULL
--   ORDER BY daily_views DESC LIMIT 10;
--
-- チャンネル全体の日次視聴回数（ショート動画とそれ以外の内訳つき）
--   SELECT metric_date,
--          sum(daily_views)                                    AS daily_views,
--          sum(CASE WHEN is_short THEN daily_views ELSE 0 END) AS shorts_views
--   FROM youtube_stats.daily_metrics
--   WHERE daily_views IS NOT NULL
--   GROUP BY metric_date
--   ORDER BY metric_date DESC LIMIT 30;
