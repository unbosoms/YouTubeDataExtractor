FROM public.ecr.aws/lambda/python:3.11

COPY requirements.txt .
RUN pip install --no-cache-dir --prefer-binary -r requirements.txt

COPY youtube_stats_extractor.py s3_store.py lambda_handler.py ./

CMD ["lambda_handler.handler"]
