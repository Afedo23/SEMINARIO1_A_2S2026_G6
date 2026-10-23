#!/usr/bin/env bash
# 11 - Compila el frontend (React/Vite) y lo sube al bucket del sitio.
#   - Con CloudFront (10-cloudfront.sh): la API se llama por /api en el mismo dominio HTTPS.
#   - Sin CloudFront: apunta directo al ALB (HTTP; la camara no funcionara).
# Requiere haber corrido 07 (UPLOAD_API_URL). Necesita Node 18+ (CloudShell lo trae).
cd "$(dirname "$0")"; source ./00-env.sh
: "${UPLOAD_API_URL:?Falta UPLOAD_API_URL: corre 07-serverless.sh}"

if [ -n "${CF_ID:-}" ]; then API_URL=""; else : "${ALB_DNS:?Falta ALB_DNS}"; API_URL="http://$ALB_DNS"; fi

need_dir "$ROOT/frontend" frontend
cd "$ROOT/frontend"
cat > .env.production <<ENV
VITE_API_URL=$API_URL
VITE_UPLOAD_URL=$UPLOAD_API_URL
ENV

npm install --no-audit --no-fund
npm run build
aws s3 sync dist "s3://$WEB_BUCKET" --delete

if [ -n "${CF_ID:-}" ]; then
  aws cloudfront create-invalidation --distribution-id "$CF_ID" --paths '/*' >/dev/null
  echo "OK  Sitio: https://$CF_DOMAIN"
else
  echo "OK  Sitio: http://$WEB_BUCKET.s3-website-$AWS_REGION.amazonaws.com"
fi
