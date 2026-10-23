#!/usr/bin/env bash
# Borra una VPC "huerfana" creada por 01-network.sh (sin instancias ni RDS dentro).
#   bash cleanup-vpc.sh vpc-08046ffa2e6adb5dc
cd "$(dirname "$0")"; source ./00-env.sh
V="${1:?uso: bash cleanup-vpc.sh vpc-xxxx}"
[ "$V" != "${VPC_ID:-}" ] || [ -n "${FORCE:-}" ] || { echo "Esa es la VPC EN USO (VPC_ID). No se borra."; exit 1; }

for sg in $(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$V" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
  r=$(aws ec2 describe-security-group-rules --filters Name=group-id,Values="$sg" --query 'SecurityGroupRules[?IsEgress==`false`].SecurityGroupRuleId' --output text)
  [ -n "$r" ] && aws ec2 revoke-security-group-ingress --group-id "$sg" --security-group-rule-ids $r >/dev/null
done
for sg in $(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$V" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
  aws ec2 delete-security-group --group-id "$sg"
done
for s in $(aws ec2 describe-subnets --filters Name=vpc-id,Values="$V" --query 'Subnets[].SubnetId' --output text); do
  aws ec2 delete-subnet --subnet-id "$s"
done
for rt in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$V" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text); do
  aws ec2 delete-route-table --route-table-id "$rt"
done
for ig in $(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="$V" --query 'InternetGateways[].InternetGatewayId' --output text); do
  aws ec2 detach-internet-gateway --internet-gateway-id "$ig" --vpc-id "$V"
  aws ec2 delete-internet-gateway --internet-gateway-id "$ig"
done
aws ec2 delete-vpc --vpc-id "$V"
echo "OK: $V eliminada"
