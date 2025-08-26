import boto3
from PIL import Image
import os

s3 = boto3.client('s3')

def lambda_handler(event, context):
    bucket = event['Records'][0]['s3']['bucket']['name']
    key = event['Records'][0]['s3']['object']['key']
    
    download_path = f"/tmp/{os.path.basename(key)}"
    upload_path = f"/tmp/resized-{os.path.basename(key)}"

    s3.download_file(bucket, key, download_path)

    with Image.open(download_path) as img:
        img = img.resize((200, 200))
        img.save(upload_path)

    dest_bucket = os.environ['DEST_BUCKET']
    s3.upload_file(upload_path, dest_bucket, f"resized-{os.path.basename(key)}")

    return {"status": "success", "file": f"resized-{key}"}
