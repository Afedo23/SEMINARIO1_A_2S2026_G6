#!/usr/bin/env bash
# 09 - Ejecuta un archivo SQL en la RDS primaria (por defecto db/schema.sql).
#   bash 09-schema.sh                    # instalacion nueva: crea todas las tablas
#   bash 09-schema.sh db/001_likes.sql   # migracion: agrega la tabla de "me gusta" (segura de repetir)
# RDS es privada, asi que el SQL se ejecuta desde una EC2 usando SSM (sin SSH ni puertos abiertos).
cd "$(dirname "$0")"; source ./00-env.sh
SQL="${1:-db/schema.sql}"
[ -f "$ROOT/$SQL" ] || { echo "ERROR: no encuentro $ROOT/$SQL"; exit 1; }

cp "$ROOT/$SQL" "$T/script.sql"
aws s3 cp "$T/script.sql" "s3://$IMG_BUCKET/deploy/script.sql"

IID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$PROJ-node" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$IID" != "None" ] || { echo "No hay EC2 node en running. Corre 06-compute.sh primero."; exit 1; }

for _ in $(seq 1 30); do
  S=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$IID" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
  [ "$S" = "Online" ] && break; echo "Esperando SSM ($S)..."; sleep 10
done

cat > "$T/params.json" <<JSON
{"commands":[
 "aws s3 cp s3://$IMG_BUCKET/deploy/script.sql /tmp/script.sql --region $AWS_REGION",
 "set -a; . /etc/semisocial.env; set +a; PGPASSWORD=\$DB_PASSWORD psql \"host=\$DB_WRITE_HOST dbname=\$DB_NAME user=\$DB_USER sslmode=require\" -v ON_ERROR_STOP=1 -f /tmp/script.sql"
]}
JSON

CMD=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters "file://$T/params.json" --query Command.CommandId --output text)
aws ssm wait command-executed --command-id "$CMD" --instance-id "$IID" || true

aws ssm get-command-invocation --command-id "$CMD" --instance-id "$IID" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
echo "Si Status = Success, el SQL se ejecuto."
