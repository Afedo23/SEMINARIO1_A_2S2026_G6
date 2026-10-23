#!/usr/bin/env bash
# 02 - IAM: roles (EC2, Lambda) y usuarios separados por servicio (rubrica 1.1)
cd "$(dirname "$0")"; source ./00-env.sh
ig() { "$@" 2>/dev/null || true; }   # ignora "ya existe" al re-ejecutar

cat > "$T/trust-ec2.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
cat > "$T/trust-lambda.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

# ---- Rol de los backends EC2 ----
cat > "$T/ec2-policy.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"IA","Effect":"Allow","Action":["polly:SynthesizeSpeech","translate:TranslateText","rekognition:DetectLabels","rekognition:CompareFaces","lex:RecognizeText","comprehend:DetectDominantLanguage"],"Resource":"*"},
 {"Sid":"S3Imagenes","Effect":"Allow","Action":["s3:GetObject","s3:PutObject"],"Resource":"arn:aws:s3:::$IMG_BUCKET/*"},
 {"Sid":"Secretos","Effect":"Allow","Action":"ssm:GetParameter","Resource":"arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter$SSM_PREFIX/*"},
 {"Sid":"Cognito","Effect":"Allow","Action":["cognito-idp:AdminGetUser","cognito-idp:AdminUpdateUserAttributes","cognito-idp:AdminInitiateAuth","cognito-idp:AdminSetUserPassword"],"Resource":"arn:aws:cognito-idp:$AWS_REGION:$ACCOUNT_ID:userpool/*"}
]}
EOF
ig aws iam create-role --role-name "$PROJ-ec2-role" --assume-role-policy-document "file://$T/trust-ec2.json" >/dev/null
aws iam put-role-policy --role-name "$PROJ-ec2-role" --policy-name servicios-app --policy-document "file://$T/ec2-policy.json"
aws iam attach-role-policy --role-name "$PROJ-ec2-role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
ig aws iam create-instance-profile --instance-profile-name "$PROJ-ec2-profile" >/dev/null
ig aws iam add-role-to-instance-profile --instance-profile-name "$PROJ-ec2-profile" --role-name "$PROJ-ec2-role"
save EC2_PROFILE "$PROJ-ec2-profile"

# ---- Rol de las Lambdas (subida de imagenes + Rekognition) ----
cat > "$T/lambda-policy.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:PutObject","s3:GetObject"],"Resource":["arn:aws:s3:::$IMG_BUCKET/Fotos_Perfil/*","arn:aws:s3:::$IMG_BUCKET/Fotos_Publicadas/*"]},
 {"Effect":"Allow","Action":["rekognition:DetectLabels","rekognition:CompareFaces"],"Resource":"*"}
]}
EOF
ig aws iam create-role --role-name "$PROJ-lambda-role" --assume-role-policy-document "file://$T/trust-lambda.json" >/dev/null
aws iam put-role-policy --role-name "$PROJ-lambda-role" --policy-name s3-rekognition --policy-document "file://$T/lambda-policy.json"
aws iam attach-role-policy --role-name "$PROJ-lambda-role" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
save LAMBDA_ROLE_ARN "arn:aws:iam::$ACCOUNT_ID:role/$PROJ-lambda-role"

# ---- Usuarios IAM por servicio (sin access keys: se crean desde consola si las necesitan) ----
cat > "$T/user-s3.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:*","Resource":["arn:aws:s3:::$IMG_BUCKET","arn:aws:s3:::$IMG_BUCKET/*","arn:aws:s3:::$WEB_BUCKET","arn:aws:s3:::$WEB_BUCKET/*"]}]}
EOF
ig aws iam create-user --user-name "$PROJ-s3" >/dev/null
aws iam put-user-policy --user-name "$PROJ-s3" --policy-name s3-buckets-proyecto --policy-document "file://$T/user-s3.json"

ig aws iam create-user --user-name "$PROJ-ec2" >/dev/null
aws iam attach-user-policy --user-name "$PROJ-ec2" --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam attach-user-policy --user-name "$PROJ-ec2" --policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess

ig aws iam create-user --user-name "$PROJ-rds" >/dev/null
aws iam attach-user-policy --user-name "$PROJ-rds" --policy-arn arn:aws:iam::aws:policy/AmazonRDSFullAccess

echo "Esperando propagacion de IAM..."; sleep 15
echo "OK IAM"
