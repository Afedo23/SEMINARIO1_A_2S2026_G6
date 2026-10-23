#!/usr/bin/env bash
# Lista TODO lo que existe con el prefijo del proyecto. Tras un destroy debe salir vacio.
# Durante un despliegue activo muestra lo vivo; la VPC en uso aparece marcada.
cd "$(dirname "$0")"; source ./00-env.sh; set +eu
q() { local t="$1"; shift; local r; r=$("$@" 2>/dev/null); [ -n "$r" ] && [ "$r" != "None" ] && { echo; echo "== $t"; echo "$r"; }; }
echo "Region: $AWS_REGION   VPC en uso (.state.env): ${VPC_ID:-ninguna}"
q "CloudFront (id, estado)"   aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='Semi-Social G$GRP'].[Id,Status]" --output text
q "Auto Scaling Groups"       aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?starts_with(AutoScalingGroupName,'$PROJ-')].AutoScalingGroupName" --output text
q "Instancias EC2 vivas"      aws ec2 describe-instances --filters "Name=tag:Name,Values=$PROJ-*" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text
q "Plantillas de lanzamiento" aws ec2 describe-launch-templates --query "LaunchTemplates[?starts_with(LaunchTemplateName,'$PROJ-')].LaunchTemplateName" --output text
q "Balanceadores (nombre, VPC)" aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'$PROJ-')].[LoadBalancerName,VpcId]" --output text
q "Target groups (nombre, VPC)" aws elbv2 describe-target-groups --query "TargetGroups[?starts_with(TargetGroupName,'$PROJ-')].[TargetGroupName,VpcId]" --output text
q "RDS (id, estado)"          aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier,'$PROJ-')].[DBInstanceIdentifier,DBInstanceStatus]" --output text
q "Grupos de subredes RDS"    aws rds describe-db-subnet-groups --query "DBSubnetGroups[?starts_with(DBSubnetGroupName,'$PROJ-')].DBSubnetGroupName" --output text
q "Lambdas"                   aws lambda list-functions --query "Functions[?starts_with(FunctionName,'$PROJ-')].FunctionName" --output text
q "API Gateway (nombre, id)"  aws apigatewayv2 get-apis --query "Items[?starts_with(Name,'$PROJ-')].[Name,ApiId]" --output text
q "Lex (nombre, id)"          aws lexv2-models list-bots --query "botSummaries[?starts_with(botName,'$PROJ-')].[botName,botId]" --output text
q "Cognito (nombre, id)"      aws cognito-idp list-user-pools --max-results 60 --query "UserPools[?starts_with(Name,'$PROJ-')].[Name,Id]" --output text
q "Buckets S3"                aws s3api list-buckets --query "Buckets[?starts_with(Name,'semi1proyecto-g$GRP') || starts_with(Name,'proyecto-web-g$GRP')].Name" --output text
q "Roles IAM"                 aws iam list-roles --query "Roles[?starts_with(RoleName,'$PROJ-')].RoleName" --output text
q "Usuarios IAM"              aws iam list-users --query "Users[?starts_with(UserName,'$PROJ-')].UserName" --output text
q "Perfiles de instancia"     aws iam list-instance-profiles --query "InstanceProfiles[?starts_with(InstanceProfileName,'$PROJ-')].InstanceProfileName" --output text
q "Parametros SSM"            aws ssm describe-parameters --parameter-filters "Key=Name,Option=BeginsWith,Values=$SSM_PREFIX" --query 'Parameters[].Name' --output text
q "VPC (id, estado)"          aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$PROJ-vpc" --query 'Vpcs[].[VpcId,State]' --output text
q "Grupos de seguridad (id, nombre, VPC)" aws ec2 describe-security-groups --filters "Name=group-name,Values=$PROJ-*" --query 'SecurityGroups[].[GroupId,GroupName,VpcId]' --output text
echo; echo "(Si no se imprimio ninguna seccion, no queda nada del proyecto.)"
