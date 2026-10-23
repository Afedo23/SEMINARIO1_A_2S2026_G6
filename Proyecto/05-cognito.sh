#!/usr/bin/env bash
# 05 - Cognito: user pool (verificacion por correo) + app client
cd "$(dirname "$0")"; source ./00-env.sh

POOL_ID=$(aws cognito-idp create-user-pool \
  --pool-name "$PROJ-users" \
  --auto-verified-attributes email \
  --verification-message-template DefaultEmailOption=CONFIRM_WITH_CODE \
  --policies 'PasswordPolicy={MinimumLength=8,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=false}' \
  --schema Name=email,AttributeDataType=String,Required=true,Mutable=true \
           Name=name,AttributeDataType=String,Required=true,Mutable=true \
           Name=dpi,AttributeDataType=String,Mutable=true \
  --query UserPool.Id --output text)
save USER_POOL_ID "$POOL_ID"      # el atributo personalizado se usa como custom:dpi

CLIENT_ID=$(aws cognito-idp create-user-pool-client \
  --user-pool-id "$POOL_ID" --client-name "$PROJ-web" --no-generate-secret \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_USER_SRP_AUTH ALLOW_ADMIN_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --query UserPoolClient.ClientId --output text)
save COGNITO_CLIENT_ID "$CLIENT_ID"

echo "OK Cognito  pool=$POOL_ID  client=$CLIENT_ID"
