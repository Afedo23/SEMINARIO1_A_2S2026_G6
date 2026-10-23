#!/usr/bin/env bash
# 10 - CloudFront: una sola URL HTTPS que sirve
#        /        -> sitio estatico (bucket S3 Proyecto-Web-G6, endpoint website)
#        /api/*   -> Application Load Balancer (las dos EC2)
# Con HTTPS la camara del navegador funciona, y al ser el mismo origen no hay CORS ni "mixed content".
cd "$(dirname "$0")"; source ./00-env.sh
: "${ALB_DNS:?Falta ALB_DNS: corre 06-compute.sh}"

# Endpoint website del bucket: las regiones antiguas usan "s3-website-<region>", las nuevas "s3-website.<region>"
case "$AWS_REGION" in
  us-east-1|us-west-1|us-west-2|eu-west-1|ap-southeast-1|ap-southeast-2|ap-northeast-1|sa-east-1) SEP="-" ;;
  *) SEP="." ;;
esac
S3_WEB="$WEB_BUCKET.s3-website${SEP}${AWS_REGION}.amazonaws.com"

# IDs de las politicas administradas por AWS (se consultan, no se escriben a mano)
cache_policy() { aws cloudfront list-cache-policies --type managed \
  --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='$1'].CachePolicy.Id | [0]" --output text; }
CACHING_OPTIMIZED="$(cache_policy Managed-CachingOptimized)"
CACHING_DISABLED="$(cache_policy Managed-CachingDisabled)"
ALL_VIEWER="$(aws cloudfront list-origin-request-policies --type managed \
  --query "OriginRequestPolicyList.Items[?OriginRequestPolicy.OriginRequestPolicyConfig.Name=='Managed-AllViewer'].OriginRequestPolicy.Id | [0]" --output text)"
for v in "$CACHING_OPTIMIZED" "$CACHING_DISABLED" "$ALL_VIEWER"; do
  { [ -n "$v" ] && [ "$v" != "None" ]; } || { echo "ERROR: no pude obtener las politicas administradas de CloudFront"; exit 1; }
done
echo "Politicas: optimized=$CACHING_OPTIMIZED disabled=$CACHING_DISABLED allviewer=$ALL_VIEWER"

cat > "$T/dist.json" <<EOF
{
  "CallerReference": "$PROJ-$(date +%s)",
  "Comment": "Semi-Social G$GRP",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "PriceClass": "PriceClass_100",
  "HttpVersion": "http2",
  "Origins": { "Quantity": 2, "Items": [
    { "Id": "s3web", "DomainName": "$S3_WEB",
      "CustomOriginConfig": { "HTTPPort": 80, "HTTPSPort": 443, "OriginProtocolPolicy": "http-only" } },
    { "Id": "alb", "DomainName": "$ALB_DNS",
      "CustomOriginConfig": { "HTTPPort": 80, "HTTPSPort": 443, "OriginProtocolPolicy": "http-only", "OriginReadTimeout": 60 } }
  ] },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3web", "ViewerProtocolPolicy": "redirect-to-https", "Compress": true,
    "CachePolicyId": "$CACHING_OPTIMIZED",
    "AllowedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
  },
  "CacheBehaviors": { "Quantity": 1, "Items": [
    { "PathPattern": "/api/*", "TargetOriginId": "alb", "ViewerProtocolPolicy": "redirect-to-https", "Compress": true,
      "CachePolicyId": "$CACHING_DISABLED", "OriginRequestPolicyId": "$ALL_VIEWER",
      "AllowedMethods": { "Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
                          "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] } } }
  ] }
}
EOF

OUT=$(aws cloudfront create-distribution --distribution-config "file://$T/dist.json" \
  --query 'Distribution.[Id,DomainName]' --output text) || { echo "ERROR creando la distribucion de CloudFront"; exit 1; }
read -r CF_ID CF_DOMAIN <<< "$OUT"
[ -n "$CF_ID" ] && [ "$CF_ID" != "None" ] || { echo "ERROR: CloudFront no devolvio un ID"; exit 1; }
save CF_ID "$CF_ID"; save CF_DOMAIN "$CF_DOMAIN"

echo "Distribucion $CF_ID creada. Esperando despliegue (5-10 min)..."
aws cloudfront wait distribution-deployed --id "$CF_ID"
echo "OK  Sitio HTTPS: https://$CF_DOMAIN"
echo "Siguiente: bash 11-frontend.sh  (compila apuntando a /api del mismo dominio)"
