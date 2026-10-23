#!/usr/bin/env bash
# 01 - VPC, 2 subnets publicas (ALB + EC2), 2 privadas (RDS), security groups encadenados
cd "$(dirname "$0")"; source ./00-env.sh

# Solo AZs donde exista el tipo de instancia elegido
AZS=($(aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters Name=instance-type,Values="$INSTANCE_TYPE" \
  --query 'InstanceTypeOfferings[].Location' --output text))
[ "${#AZS[@]}" -ge 2 ] || { echo "ERROR: $INSTANCE_TYPE no esta en 2 AZs de $AWS_REGION"; exit 1; }
AZ1="${AZS[0]}"; AZ2="${AZS[1]}"
save AZ1 "$AZ1"; save AZ2 "$AZ2"

VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$PROJ-vpc}]" \
  --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
save VPC_ID "$VPC_ID"

IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
save IGW_ID "$IGW_ID"

mksubnet() { aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$1" --availability-zone "$2" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJ-$3}]" \
  --query Subnet.SubnetId --output text; }

PUB1=$(mksubnet 10.0.1.0/24 "$AZ1" pub1);  PUB2=$(mksubnet 10.0.2.0/24 "$AZ2" pub2)
PRV1=$(mksubnet 10.0.11.0/24 "$AZ1" prv1); PRV2=$(mksubnet 10.0.12.0/24 "$AZ2" prv2)
for s in "$PUB1" "$PUB2"; do aws ec2 modify-subnet-attribute --subnet-id "$s" --map-public-ip-on-launch; done
save PUB1 "$PUB1"; save PUB2 "$PUB2"; save PRV1 "$PRV1"; save PRV2 "$PRV2"

RT_PUB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id "$RT_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$PUB1" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$PUB2" >/dev/null

# ---- Security groups: Internet -> ALB(80) -> EC2(3000) -> RDS(5432). Sin SSH (se usa SSM) ----
mksg() { aws ec2 create-security-group --group-name "$PROJ-$1" --description "$2" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROJ-$1}]" \
  --query GroupId --output text; }

SG_ALB=$(mksg alb "ALB publico");  SG_EC2=$(mksg ec2 "Backends");  SG_RDS=$(mksg rds "PostgreSQL")
aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" --protocol tcp --port 80   --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_EC2" --protocol tcp --port 3000 --source-group "$SG_ALB" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_RDS" --protocol tcp --port 5432 --source-group "$SG_EC2" >/dev/null
save SG_ALB "$SG_ALB"; save SG_EC2 "$SG_EC2"; save SG_RDS "$SG_RDS"

echo "OK red: VPC=$VPC_ID AZs=$AZ1,$AZ2"
