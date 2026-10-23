#!/usr/bin/env bash
# 06 - Computo con auto-recuperacion:
#   Application Load Balancer (2 AZs) -> Target Group (/health) -> 2 Auto Scaling Groups
#   (uno Node.js, otro Python; min=1 cada uno, se reemplazan solos si caen)
# Requiere haber corrido 01..05. Cada backend DEBE exponer GET /health -> 200 en el puerto 3000.
cd "$(dirname "$0")"; source ./00-env.sh

AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)

# ---------- Parte comun del user-data (los secretos se leen de SSM en el arranque) ----------
COMMON=$(cat <<EOF
#!/bin/bash
set -ex
dnf install -y postgresql15
mkdir -p /opt/app
DBPASS=\$(aws ssm get-parameter --name $SSM_PREFIX/db_password --with-decryption --query Parameter.Value --output text --region $AWS_REGION)
JWT=\$(aws ssm get-parameter --name $SSM_PREFIX/jwt_secret --with-decryption --query Parameter.Value --output text --region $AWS_REGION)
cat > /etc/semisocial.env <<ENV
PORT=3000
AWS_REGION=$AWS_REGION
DB_WRITE_HOST=$RDS_WRITE
DB_READ_HOST=$RDS_READ
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=\$DBPASS
JWT_SECRET=\$JWT
USER_POOL_ID=$USER_POOL_ID
COGNITO_CLIENT_ID=$COGNITO_CLIENT_ID
IMG_BUCKET=$IMG_BUCKET
ENV
chmod 600 /etc/semisocial.env
EOF
)

# ---------- User-data Node.js ----------
{ echo "$COMMON"; cat <<EOF
dnf install -y nodejs npm
aws s3 cp s3://$IMG_BUCKET/deploy/backend-node.tgz /tmp/app.tgz --region $AWS_REGION && tar xzf /tmp/app.tgz -C /opt/app && (cd /opt/app && (npm ci --omit=dev || npm install --omit=dev)) || true
[ -f /opt/app/server.js ] || cat > /opt/app/server.js <<JS
require('http').createServer((q,r)=>r.end('semi-social node placeholder')).listen(3000);
JS
chown -R ec2-user:ec2-user /opt/app
cat > /etc/systemd/system/semisocial.service <<UNIT
[Unit]
Description=Semi-Social API (Node)
After=network-online.target
[Service]
User=ec2-user
WorkingDirectory=/opt/app
EnvironmentFile=/etc/semisocial.env
ExecStart=/usr/bin/node /opt/app/server.js
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now semisocial
EOF
} > "$T/ud-node.sh"

# ---------- User-data Python (FastAPI + uvicorn) ----------
{ echo "$COMMON"; cat <<EOF
dnf install -y python3 python3-pip
python3 -m venv /opt/venv
/opt/venv/bin/pip install fastapi "uvicorn[standard]" boto3 psycopg2-binary pyjwt python-multipart
aws s3 cp s3://$IMG_BUCKET/deploy/backend-python.tgz /tmp/app.tgz --region $AWS_REGION && tar xzf /tmp/app.tgz -C /opt/app || true
[ -f /opt/app/requirements.txt ] && /opt/venv/bin/pip install -r /opt/app/requirements.txt || true
[ -f /opt/app/main.py ] || cat > /opt/app/main.py <<PY
from fastapi import FastAPI
app = FastAPI()
@app.get("/health")
def health():
    return {"ok": True}
PY
chown -R ec2-user:ec2-user /opt/app
cat > /etc/systemd/system/semisocial.service <<UNIT
[Unit]
Description=Semi-Social API (Python)
After=network-online.target
[Service]
User=ec2-user
WorkingDirectory=/opt/app
EnvironmentFile=/etc/semisocial.env
ExecStart=/opt/venv/bin/uvicorn main:app --host 0.0.0.0 --port 3000
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now semisocial
EOF
} > "$T/ud-python.sh"

# ---------- Launch templates ----------
mklt() {
  local UD; UD=$(base64 -w0 "$2")     # GNU base64 (Linux / CloudShell)
  cat > "$T/$1.json" <<EOF
{"ImageId":"$AMI","InstanceType":"$INSTANCE_TYPE",
 "IamInstanceProfile":{"Name":"$EC2_PROFILE"},
 "SecurityGroupIds":["$SG_EC2"],
 "MetadataOptions":{"HttpTokens":"required"},
 "BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":16,"VolumeType":"gp3","Encrypted":true}}],
 "UserData":"$UD"}
EOF
  aws ec2 create-launch-template --launch-template-name "$PROJ-$1" --launch-template-data "file://$T/$1.json" >/dev/null
}
mklt node   "$T/ud-node.sh"
mklt python "$T/ud-python.sh"

# ---------- ALB + Target Group + Listener ----------
ALB_ARN=$(aws elbv2 create-load-balancer --name "$PROJ-alb" --type application --scheme internet-facing \
  --subnets "$PUB1" "$PUB2" --security-groups "$SG_ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
save ALB_ARN "$ALB_ARN"

TG_ARN=$(aws elbv2 create-target-group --name "$PROJ-tg" --protocol HTTP --port 3000 --vpc-id "$VPC_ID" \
  --target-type instance --health-check-protocol HTTP --health-check-path /health \
  --health-check-interval-seconds 10 --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 2 --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
save TG_ARN "$TG_ARN"
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30 Key=load_balancing.algorithm.type,Value=round_robin >/dev/null
aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN" >/dev/null
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"

# ---------- Auto Scaling Groups (auto-recuperacion con health check del ALB) ----------
mkasg() {
  aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$PROJ-$1-asg" \
    --launch-template "LaunchTemplateName=$PROJ-$1,Version=\$Latest" \
    --min-size 1 --max-size 2 --desired-capacity 1 \
    --vpc-zone-identifier "$PUB1,$PUB2" --target-group-arns "$TG_ARN" \
    --health-check-type ELB --health-check-grace-period 420 \
    --tags "Key=Name,Value=$PROJ-$1,PropagateAtLaunch=true"
}
mkasg node
mkasg python

# ---------- Esperar a que ambos esten healthy ----------
echo "Esperando targets healthy (3-8 min)..."
for _ in $(seq 1 50); do
  N=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
  echo "healthy: $N/2"; [ "$N" -ge 2 ] && break; sleep 15
done

DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)
save ALB_DNS "$DNS"
echo "OK  ALB: http://$DNS   (probar: curl http://$DNS/health varias veces)"
aws ec2 describe-instances --filters "Name=tag:Name,Values=$PROJ-node,$PROJ-python" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,Placement.AvailabilityZone]' --output table
