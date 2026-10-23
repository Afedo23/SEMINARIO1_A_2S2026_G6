#!/usr/bin/env bash
# 04 - RDS PostgreSQL: primaria (Multi-AZ) + read replica. Secretos en SSM Parameter Store.
# Uso:  export DB_PASS='UnaClaveSegura123'   (sin / @ " ni espacios)  &&  bash 04-database.sh
cd "$(dirname "$0")"; source ./00-env.sh
: "${DB_PASS:?Exporta DB_PASS antes de correr este script}"

aws ssm put-parameter --name "$SSM_PREFIX/db_password" --type SecureString --value "$DB_PASS" --overwrite >/dev/null
aws ssm put-parameter --name "$SSM_PREFIX/jwt_secret"  --type SecureString --value "$(openssl rand -hex 32)" --overwrite >/dev/null

aws rds create-db-subnet-group --db-subnet-group-name "$PROJ-db-subnets" \
  --db-subnet-group-description "Semi-Social G$GRP" --subnet-ids "$PRV1" "$PRV2" >/dev/null

MAZ=--no-multi-az; [ "$DB_MULTI_AZ" = "true" ] && MAZ=--multi-az

aws rds create-db-instance \
  --db-instance-identifier "$PROJ-db" \
  --engine postgres \
  --db-instance-class "$DB_CLASS" \
  --allocated-storage 20 --storage-type gp3 --storage-encrypted \
  --db-name "$DB_NAME" --master-username "$DB_USER" --master-user-password "$DB_PASS" \
  --vpc-security-group-ids "$SG_RDS" --db-subnet-group-name "$PROJ-db-subnets" \
  --no-publicly-accessible $MAZ \
  --backup-retention-period 1 >/dev/null     # >0 es obligatorio para poder crear replicas

echo "Creando la primaria (10-20 min)..."
aws rds wait db-instance-available --db-instance-identifier "$PROJ-db"

aws rds create-db-instance-read-replica \
  --db-instance-identifier "$PROJ-db-replica" \
  --source-db-instance-identifier "$PROJ-db" \
  --db-instance-class "$DB_CLASS" \
  --vpc-security-group-ids "$SG_RDS" \
  --no-publicly-accessible >/dev/null

echo "Creando la replica (10-15 min)..."
aws rds wait db-instance-available --db-instance-identifier "$PROJ-db-replica"

ep() { aws rds describe-db-instances --db-instance-identifier "$1" --query 'DBInstances[0].Endpoint.Address' --output text; }
save RDS_WRITE "$(ep "$PROJ-db")"
save RDS_READ  "$(ep "$PROJ-db-replica")"
echo "OK RDS  write=$RDS_WRITE  read=$RDS_READ"
echo "Cargar el esquema (desde una EC2 por SSM): psql -h $RDS_WRITE -U $DB_USER -d $DB_NAME -f schema.sql"
