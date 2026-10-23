#!/usr/bin/env bash
# 03 - S3: bucket de imagenes (Fotos_Perfil / Fotos_Publicadas) y bucket del sitio estatico
cd "$(dirname "$0")"; source ./00-env.sh

mkbucket() {
  if aws s3api head-bucket --bucket "$1" >/dev/null 2>&1; then echo "Bucket $1 ya existe y es tuyo, se reutiliza"; return 0; fi
  local out
  if [ "$AWS_REGION" = "us-east-1" ]; then out=$(aws s3api create-bucket --bucket "$1" 2>&1) || true
  else out=$(aws s3api create-bucket --bucket "$1" --create-bucket-configuration LocationConstraint="$AWS_REGION" 2>&1) || true; fi
  if ! aws s3api head-bucket --bucket "$1" >/dev/null 2>&1; then
    echo "$out"
    echo "ERROR: el nombre '$1' no esta disponible (lo usa otra cuenta). Prueba otro sufijo:  export BUCKET_SUFFIX=-g6b  y reintenta."
    exit 1
  fi
}
open_public() {  # quita el bloqueo de acceso publico del bucket
  aws s3api put-public-access-block --bucket "$1" --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false
}

echo '{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","PUT","POST","HEAD"],"AllowedHeaders":["*"],"MaxAgeSeconds":3000}]}' > "$T/cors.json"

# ---- Imagenes ----
mkbucket "$IMG_BUCKET"; open_public "$IMG_BUCKET"
aws s3api put-object --bucket "$IMG_BUCKET" --key Fotos_Perfil/ >/dev/null
aws s3api put-object --bucket "$IMG_BUCKET" --key Fotos_Publicadas/ >/dev/null
cat > "$T/img-policy.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"LecturaPublicaFotos","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":["arn:aws:s3:::$IMG_BUCKET/Fotos_Perfil/*","arn:aws:s3:::$IMG_BUCKET/Fotos_Publicadas/*"]}]}
EOF
aws s3api put-bucket-policy --bucket "$IMG_BUCKET" --policy "file://$T/img-policy.json"
aws s3api put-bucket-cors   --bucket "$IMG_BUCKET" --cors-configuration "file://$T/cors.json"

# ---- Sitio web estatico ----
mkbucket "$WEB_BUCKET"; open_public "$WEB_BUCKET"
aws s3 website "s3://$WEB_BUCKET" --index-document index.html --error-document index.html
cat > "$T/web-policy.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"LecturaPublicaSitio","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::$WEB_BUCKET/*"}]}
EOF
aws s3api put-bucket-policy --bucket "$WEB_BUCKET" --policy "file://$T/web-policy.json"

echo "Buckets: imagenes=$IMG_BUCKET  sitio=$WEB_BUCKET"
echo "OK S3  ->  http://$WEB_BUCKET.s3-website-$AWS_REGION.amazonaws.com"
echo "Subir el frontend:  aws s3 sync ./build s3://$WEB_BUCKET --delete"
echo "Subir los backends: aws s3 cp backend-node.tgz s3://$IMG_BUCKET/deploy/   (y backend-python.tgz)"
