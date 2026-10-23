#!/usr/bin/env bash
# Publica una nueva version de un backend SIN caida:
#   bash redeploy.sh node      (empaqueta ../backend-node)
#   bash redeploy.sh python    (empaqueta ../backend-python)
# Sube el .tgz a S3 y lanza un instance refresh: primero levanta la instancia nueva
# (healthy en el ALB) y despues termina la vieja.
cd "$(dirname "$0")"; source ./00-env.sh
W="${1:?uso: bash redeploy.sh node|python}"
case "$W" in
  node)   DIR="$ROOT/backend-node" ;;
  python) DIR="$ROOT/backend-python" ;;
  *) echo "usa node o python"; exit 1 ;;
esac

need_dir "$DIR" "backend-$W"
tar czf "$T/backend-$W.tgz" -C "$DIR" --exclude=node_modules --exclude=venv --exclude=__pycache__ .
aws s3 cp "$T/backend-$W.tgz" "s3://$IMG_BUCKET/deploy/backend-$W.tgz"

aws autoscaling start-instance-refresh --auto-scaling-group-name "$PROJ-$W-asg" \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":200,"InstanceWarmup":120}'
echo "Refresh iniciado. Estado: aws autoscaling describe-instance-refreshes --auto-scaling-group-name $PROJ-$W-asg"
