"""AWS Lambdaのエントリーポイント。

EventBridge Schedulerから毎時起動され、YouTube統計をS3へParquetで保存する。
GitHub Actionsのschedule実行は遅延・スキップが頻発するため、確実な定期実行を
Lambdaに任せる構成（TableauPublicDataExtractと同じ）。

必要な環境変数はSETUP_LAMBDA.mdを参照。
"""

import youtube_stats_extractor


def handler(event, context):
    youtube_stats_extractor.main()
    return {'statusCode': 200, 'body': 'OK'}
