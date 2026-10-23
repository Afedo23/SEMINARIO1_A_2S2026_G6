#!/usr/bin/env bash
# destroy.sh - BORRA todo lo que crearon los scripts 01 a 11, para dejar de pagar.
# IRREVERSIBLE: se pierden la base de datos, las imagenes y los usuarios.
# Para volver a levantar el proyecto: export DB_PASS=...  y  bash deploy.sh  (desde el paso 01).
# NO lo corras antes de que los auxiliares califiquen: la calificacion exige la app desplegada.
cd "$(dirname "$0")"; source ./00-env.sh
echo "Se borrara TODO el proyecto '$PROJ' en $AWS_REGION (cuenta $ACCOUNT_ID)."
read -r -p "Escribe BORRAR para continuar: " R
[ "$R" = "BORRAR" ] || { echo "Cancelado."; exit 1; }
set +eu      # seguir aunque algun recurso ya no exista
step() { echo; echo ">>> $*"; }

step "CloudFront (se desactiva, se espera y se borra: ~10 min)"
for id in $(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='Semi-Social G$GRP'].Id" --output text 2>/dev/null); do
  [ "$id" = "None" ] && continue
  aws cloudfront get-distribution-config --id "$id" > "$T/cf.json"
  ETAG=$("$PY" -c "import json;print(json.load(open('$T/cf.json'))['ETag'])" | tr -d '\r')
  "$PY" -c "import json;c=json.load(open('$T/cf.json'))['DistributionConfig'];c['Enabled']=False;json.dump(c,open('$T/cf-off.json','w'))"
  aws cloudfront update-distribution --id "$id" --if-match "$ETAG" --distribution-config "file://$T/cf-off.json" >/dev/null
  aws cloudfront wait distribution-deployed --id "$id"
  ETAG=$(aws cloudfront get-distribution --id "$id" --query ETag --output text | tr -d '\r')
  aws cloudfront delete-distribution --id "$id" --if-match "$ETAG" && echo "CloudFront $id borrada"
done

step "Auto Scaling Groups y plantillas (terminan las EC2)"
for g in $(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?starts_with(AutoScalingGroupName,'$PROJ-')].AutoScalingGroupName" --output text); do
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$g" --force-delete
done
for _ in $(seq 1 40); do
  n=$(aws autoscaling describe-auto-scaling-groups --query "length(AutoScalingGroups[?starts_with(AutoScalingGroupName,'$PROJ-')])" --output text)
  [ "$n" = "0" ] && break; echo "esperando a que terminen las instancias..."; sleep 15
done
for lt in $(aws ec2 describe-launch-templates --query "LaunchTemplates[?starts_with(LaunchTemplateName,'$PROJ-')].LaunchTemplateName" --output text); do
  aws ec2 delete-launch-template --launch-template-name "$lt" >/dev/null
done

step "Balanceador y target group"
for ALB in $(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'$PROJ-')].LoadBalancerArn" --output text); do
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB"
done
for TG in $(aws elbv2 describe-target-groups --query "TargetGroups[?starts_with(TargetGroupName,'$PROJ-')].TargetGroupArn" --output text); do
  for i in 1 2 3 4 5 6 7 8 9 10; do
    aws elbv2 delete-target-group --target-group-arn "$TG" 2>/dev/null && { echo "target group borrado"; break; }
    echo "target group aun en uso, reintentando ($i/10)..."; sleep 15
  done
done

step "RDS: replica y primaria (sin copia final; ~10 min)"
aws rds delete-db-instance --db-instance-identifier "$PROJ-db-replica" --skip-final-snapshot >/dev/null 2>&1 \
  && aws rds wait db-instance-deleted --db-instance-identifier "$PROJ-db-replica"
aws rds delete-db-instance --db-instance-identifier "$PROJ-db" --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 \
  && aws rds wait db-instance-deleted --db-instance-identifier "$PROJ-db"
aws rds delete-db-subnet-group --db-subnet-group-name "$PROJ-db-subnets"

step "Lambda, API Gateway, Lex y Cognito"
aws lambda delete-function --function-name "$PROJ-upload"
aws lambda delete-function --function-name "$PROJ-lex-fulfillment"
for a in $(aws apigatewayv2 get-apis --query "Items[?starts_with(Name,'$PROJ-')].ApiId" --output text); do aws apigatewayv2 delete-api --api-id "$a"; done
for b in $(aws lexv2-models list-bots --query "botSummaries[?starts_with(botName,'$PROJ-')].botId" --output text); do
  aws lexv2-models delete-bot --bot-id "$b" --skip-resource-in-use-check >/dev/null
done
for u in $(aws cognito-idp list-user-pools --max-results 60 --query "UserPools[?starts_with(Name,'$PROJ-')].Id" --output text); do
  aws cognito-idp delete-user-pool --user-pool-id "$u"
done

step "S3 (se vacian y se borran los dos buckets)"
aws s3 rb "s3://$IMG_BUCKET" --force
aws s3 rb "s3://$WEB_BUCKET" --force

step "Parametros de SSM"
aws ssm delete-parameters --names "$SSM_PREFIX/db_password" "$SSM_PREFIX/jwt_secret" "$SSM_PREFIX/bot_id" "$SSM_PREFIX/bot_alias_id" >/dev/null

step "IAM"
aws iam remove-role-from-instance-profile --instance-profile-name "$PROJ-ec2-profile" --role-name "$PROJ-ec2-role"
aws iam delete-instance-profile --instance-profile-name "$PROJ-ec2-profile"
aws iam delete-role-policy --role-name "$PROJ-ec2-role" --policy-name servicios-app
aws iam detach-role-policy --role-name "$PROJ-ec2-role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name "$PROJ-ec2-role"
aws iam delete-role-policy --role-name "$PROJ-lambda-role" --policy-name s3-rekognition
aws iam detach-role-policy --role-name "$PROJ-lambda-role" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name "$PROJ-lambda-role"
aws iam delete-role-policy --role-name "$PROJ-lex-role" --policy-name polly
aws iam delete-role --role-name "$PROJ-lex-role"
aws iam delete-user-policy --user-name "$PROJ-s3" --policy-name s3-buckets-proyecto
aws iam delete-user --user-name "$PROJ-s3"
aws iam detach-user-policy --user-name "$PROJ-ec2" --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam detach-user-policy --user-name "$PROJ-ec2" --policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess
aws iam delete-user --user-name "$PROJ-ec2"
aws iam detach-user-policy --user-name "$PROJ-rds" --policy-arn arn:aws:iam::aws:policy/AmazonRDSFullAccess
aws iam delete-user --user-name "$PROJ-rds"

step "Red: todas las VPC del proyecto (tambien las huerfanas de corridas anteriores)"
VPCS="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$PROJ-vpc" --query 'Vpcs[].VpcId' --output text) ${VPC_ID:-}"
for V in $(echo $VPCS | tr ' ' '\n' | sort -u); do
  [ -z "$V" ] || [ "$V" = "None" ] && continue
  echo "VPC $V"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    FORCE=1 bash ./cleanup-vpc.sh "$V" && break
    echo "reintentando en 30 s (intento $i/10)..."; sleep 30
  done
done

mv -f .state.env .state.env.bak 2>/dev/null
echo; echo "Listo. Se guardo .state.env.bak y se creara uno nuevo al volver a correr deploy.sh."
echo; echo ">>> Verificacion de restos (debe salir vacio):"
bash ./restos.sh
