"""Lambda de carga de imagenes (detras de API Gateway).

POST /upload   body JSON:
  { "folder": "Fotos_Perfil" | "Fotos_Publicadas",
    "contentType": "image/jpeg" | "image/png",
    "imageBase64": "<base64 sin prefijo data:>" }

- Guarda el archivo en S3 (semi1proyecto-g6/<folder>/<uuid>.<ext>)
- Si folder == Fotos_Publicadas, llama a Rekognition DetectLabels y devuelve las etiquetas
Limite: ~4 MB por imagen (Lambda sincrona admite 6 MB y base64 pesa ~33% mas).
"""
import base64
import json
import os
import uuid

import boto3

s3 = boto3.client("s3")
rek = boto3.client("rekognition")

BUCKET = os.environ["IMG_BUCKET"]
REGION = os.environ.get("AWS_REGION", "us-east-1")
FOLDERS = {"Fotos_Perfil", "Fotos_Publicadas"}
TYPES = {"image/jpeg": "jpg", "image/png": "png"}  # Rekognition solo acepta jpg/png
MAX_BYTES = 4 * 1024 * 1024


def respond(code, body):
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    try:
        data = json.loads(event.get("body") or "{}")
        folder = data.get("folder")
        ctype = data.get("contentType")
        if folder not in FOLDERS:
            return respond(400, {"error": "folder invalido"})
        if ctype not in TYPES:
            return respond(400, {"error": "solo se permite image/jpeg o image/png"})
        raw = base64.b64decode(data.get("imageBase64", ""), validate=True)
        if not raw or len(raw) > MAX_BYTES:
            return respond(400, {"error": "imagen vacia o mayor a 4 MB"})
    except Exception:
        return respond(400, {"error": "solicitud invalida"})

    key = f"{folder}/{uuid.uuid4().hex}.{TYPES[ctype]}"
    s3.put_object(Bucket=BUCKET, Key=key, Body=raw, ContentType=ctype)

    out = {
        "key": key,
        "url": f"https://{BUCKET}.s3.{REGION}.amazonaws.com/{key}",
        "labels": [],
    }
    if folder == "Fotos_Publicadas":
        r = rek.detect_labels(
            Image={"S3Object": {"Bucket": BUCKET, "Name": key}},
            MaxLabels=10,
            MinConfidence=75,
        )
        out["labels"] = [
            {"name": l["Name"], "confidence": round(l["Confidence"], 2)}
            for l in r["Labels"]
        ]
    return respond(200, out)
