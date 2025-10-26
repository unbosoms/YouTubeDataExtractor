#!/usr/bin/env python3
"""
YouTube Channel Video Statistics Extractor

このスクリプトは指定されたYouTubeチャンネルの全動画の統計情報を取得します。
取得する情報：動画タイトル、公開日、視聴数、いいね数、コメント数など
"""

import os
from datetime import datetime
from typing import List, Dict
from dotenv import load_dotenv
from googleapiclient.discovery import build
import pandas as pd


class YouTubeStatsExtractor:
    """YouTubeチャンネルの動画統計情報を取得するクラス"""

    def __init__(self, api_key: str):
        """
        初期化

        Args:
            api_key: YouTube Data API v3のAPIキー
        """
        self.api_key = api_key
        self.youtube = build('youtube', 'v3', developerKey=api_key)

    def get_channel_uploads_playlist_id(self, channel_id: str) -> str:
        """
        チャンネルのアップロードプレイリストIDを取得

        Args:
            channel_id: YouTubeチャンネルID

        Returns:
            アップロードプレイリストID
        """
        request = self.youtube.channels().list(
            part='contentDetails',
            id=channel_id
        )
        response = request.execute()

        if not response.get('items'):
            raise ValueError(f"チャンネルID {channel_id} が見つかりません")

        playlist_id = response['items'][0]['contentDetails']['relatedPlaylists']['uploads']
        return playlist_id

    def get_video_ids_from_playlist(self, playlist_id: str) -> List[str]:
        """
        プレイリストから全ての動画IDを取得

        Args:
            playlist_id: プレイリストID

        Returns:
            動画IDのリスト
        """
        video_ids = []
        next_page_token = None

        while True:
            request = self.youtube.playlistItems().list(
                part='contentDetails',
                playlistId=playlist_id,
                maxResults=50,
                pageToken=next_page_token
            )
            response = request.execute()

            for item in response['items']:
                video_ids.append(item['contentDetails']['videoId'])

            next_page_token = response.get('nextPageToken')
            if not next_page_token:
                break

        return video_ids

    def get_video_statistics(self, video_ids: List[str]) -> List[Dict]:
        """
        動画IDのリストから統計情報を取得

        Args:
            video_ids: 動画IDのリスト

        Returns:
            動画統計情報の辞書のリスト
        """
        all_video_stats = []

        # APIは一度に最大50件まで取得可能
        for i in range(0, len(video_ids), 50):
            batch_ids = video_ids[i:i+50]

            request = self.youtube.videos().list(
                part='snippet,statistics,contentDetails',
                id=','.join(batch_ids)
            )
            response = request.execute()

            for item in response['items']:
                video_stats = {
                    'video_id': item['id'],
                    'title': item['snippet']['title'],
                    'published_at': item['snippet']['publishedAt'],
                    'view_count': item['statistics'].get('viewCount', 0),
                    'like_count': item['statistics'].get('likeCount', 0),
                    'comment_count': item['statistics'].get('commentCount', 0),
                    'duration': item['contentDetails']['duration'],
                    'description': item['snippet']['description'],
                    'thumbnail_url': item['snippet']['thumbnails']['default']['url'],
                    'video_url': f"https://www.youtube.com/watch?v={item['id']}"
                }
                all_video_stats.append(video_stats)

        return all_video_stats

    def extract_channel_stats(self, channel_id: str) -> pd.DataFrame:
        """
        チャンネルの全動画統計情報を取得しDataFrameで返す

        Args:
            channel_id: YouTubeチャンネルID

        Returns:
            動画統計情報のDataFrame
        """
        print(f"チャンネルID {channel_id} の動画情報を取得中...")

        # アップロードプレイリストIDを取得
        playlist_id = self.get_channel_uploads_playlist_id(channel_id)
        print(f"プレイリストID: {playlist_id}")

        # 全動画IDを取得
        video_ids = self.get_video_ids_from_playlist(playlist_id)
        print(f"動画数: {len(video_ids)}件")

        # 動画統計情報を取得
        print("動画の詳細情報を取得中...")
        video_stats = self.get_video_statistics(video_ids)

        # DataFrameに変換
        df = pd.DataFrame(video_stats)

        # データ型を変換
        df['published_at'] = pd.to_datetime(df['published_at'])
        df['view_count'] = pd.to_numeric(df['view_count'])
        df['like_count'] = pd.to_numeric(df['like_count'])
        df['comment_count'] = pd.to_numeric(df['comment_count'])

        # 公開日順にソート
        df = df.sort_values('published_at', ascending=False)

        return df


def main():
    """メイン関数"""
    # .envファイルから環境変数を読み込み
    load_dotenv()

    api_key = os.getenv('YOUTUBE_API_KEY')
    channel_id = os.getenv('YOUTUBE_CHANNEL_ID')
    output_file = os.getenv('OUTPUT_FILE', 'youtube_stats.csv')

    # 環境変数のチェック
    if not api_key:
        raise ValueError("YOUTUBE_API_KEYが設定されていません。.envファイルを確認してください。")
    if not channel_id:
        raise ValueError("YOUTUBE_CHANNEL_IDが設定されていません。.envファイルを確認してください。")

    # 統計情報を取得
    extractor = YouTubeStatsExtractor(api_key)
    df = extractor.extract_channel_stats(channel_id)

    # CSVファイルに保存
    df.to_csv(output_file, index=False, encoding='utf-8-sig')
    print(f"\n統計情報を {output_file} に保存しました")

    # 基本統計を表示
    print("\n=== 基本統計 ===")
    print(f"総動画数: {len(df)}件")
    print(f"総視聴回数: {df['view_count'].sum():,}回")
    print(f"平均視聴回数: {df['view_count'].mean():,.0f}回")
    print(f"総いいね数: {df['like_count'].sum():,}件")
    print(f"総コメント数: {df['comment_count'].sum():,}件")

    # 最も視聴された動画トップ5
    print("\n=== 最も視聴された動画 トップ5 ===")
    top_videos = df.nlargest(5, 'view_count')[['title', 'view_count', 'published_at']]
    for idx, row in top_videos.iterrows():
        print(f"{row['title'][:50]}... - {row['view_count']:,}回視聴 ({row['published_at'].date()})")


if __name__ == '__main__':
    main()
