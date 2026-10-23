#!/usr/bin/env bash
# 07 - Lambda (carga de imagenes + Rekognition) y API Gateway HTTP API
cd "$(dirname "$0")"; source ./00-env.sh

need_dir "$ROOT/lambda/upload" lambda
[ -n "$PY" ] || { echo "Instala Python (python3 o python) para empaquetar la Lambda"; exit 1; }
(cd "$ROOT/lambda/upload" && "$PY" -m zipfile -c upload.zip handler.py && mv -f upload.zip "$SD/$T/upload.zip")

LAMBDA_ARN=$(aws lambda create-function \
  --function-name "$PROJ-upload" --runtime python3.12 --handler handler.lambda_handler \
  --role "$LAMBDA_ROLE_ARN" --zip-file "fileb://$T/upload.zip" \
  --timeout 30 --memory-size 512 \
  --environment "Variables={IMG_BUCKET=$IMG_BUCKET}" \
  --query FunctionArn --output text)
save UPLOAD_LAMBDA_ARN "$LAMBDA_ARN"
aws lambda wait function-active-v2 --function-name "$PROJ-upload"

API_ID=$(aws apigatewayv2 create-api --name "$PROJ-api" --protocol-type HTTP \
  --cors-configuration '{"AllowOrigins":["*"],"AllowMethods":["POST","OPTIONS"],"AllowHeaders":["content-type"],"MaxAge":3600}' \
  --query ApiId --output text)
save API_ID "$API_ID"

INT_ID=$(aws apigatewayv2 create-integration --api-id "$API_ID" --integration-type AWS_PROXY \
  --integration-uri "$LAMBDA_ARN" --payload-format-version 2.0 --query IntegrationId --output text)
aws apigatewayv2 create-route --api-id "$API_ID" --route-key 'POST /upload' --target "integrations/$INT_ID" >/dev/null
aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy >/dev/null

aws lambda add-permission --function-name "$PROJ-upload" --statement-id apigw-invoke \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*/*/upload" >/dev/null

save UPLOAD_API_URL "https://$API_ID.execute-api.$AWS_REGION.amazonaws.com/upload"
echo "OK  POST $UPLOAD_API_URL"
echo "Prueba:  curl -X POST $UPLOAD_API_URL -H 'content-type: application/json' -d '{\"folder\":\"Fotos_Perfil\",\"contentType\":\"image/png\",\"imageBase64\":\"...\"}'"
