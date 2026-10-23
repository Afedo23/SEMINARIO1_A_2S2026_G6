#!/usr/bin/env bash
# 08 - Amazon Lex V2: bot de la Facultad (es_419) con Lambda de respuestas dinamicas
cd "$(dirname "$0")"; source ./00-env.sh
LOCALE=es_419

# ---- Lambda de fulfillment ----
need_dir "$ROOT/lambda/lex" lambda
[ -n "$PY" ] || { echo "Instala Python (python3 o python) para empaquetar la Lambda"; exit 1; }
(cd "$ROOT/lambda/lex" && "$PY" -m zipfile -c lex.zip handler.py && mv -f lex.zip "$SD/$T/lex.zip")
LEX_LAMBDA_ARN=$(aws lambda create-function --function-name "$PROJ-lex-fulfillment" \
  --runtime python3.12 --handler handler.lambda_handler --role "$LAMBDA_ROLE_ARN" \
  --zip-file "fileb://$T/lex.zip" --timeout 10 --query FunctionArn --output text)
aws lambda wait function-active-v2 --function-name "$PROJ-lex-fulfillment"
save LEX_LAMBDA_ARN "$LEX_LAMBDA_ARN"

# ---- Rol del bot ----
cat > "$T/trust-lex.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lexv2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
cat > "$T/lex-policy.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["polly:SynthesizeSpeech"],"Resource":"*"}]}
EOF
aws iam create-role --role-name "$PROJ-lex-role" --assume-role-policy-document "file://$T/trust-lex.json" >/dev/null
aws iam put-role-policy --role-name "$PROJ-lex-role" --policy-name polly --policy-document "file://$T/lex-policy.json"
sleep 10

# ---- Bot + locale ----
BOT_ID=$(aws lexv2-models create-bot --bot-name "$PROJ-bot" \
  --role-arn "arn:aws:iam::$ACCOUNT_ID:role/$PROJ-lex-role" \
  --data-privacy childDirected=false --idle-session-ttl-in-seconds 300 \
  --query botId --output text)
save BOT_ID "$BOT_ID"
aws lexv2-models wait bot-available --bot-id "$BOT_ID"

aws lexv2-models create-bot-locale --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE" \
  --nlu-intent-confidence-threshold 0.4 >/dev/null
aws lexv2-models wait bot-locale-created --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE"

# ---- Intents (los nombres deben coincidir con handler.py) ----
mkintent() {
  local name="$1"; shift
  "$PY" -c 'import sys,json; print(json.dumps([{"utterance":a} for a in sys.argv[1:]]))' "$@" > "$T/utt.json"
  aws lexv2-models create-intent --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE" \
    --intent-name "$name" --sample-utterances "file://$T/utt.json" --fulfillment-code-hook enabled=true >/dev/null
}
mkintent Saludo      "hola" "buenos días" "buenas tardes" "qué tal"
mkintent Horarios    "cuál es el horario" "a qué hora abren" "horario de atención" "a qué hora cierran"
mkintent Ubicacion   "dónde queda la facultad" "cómo llego a ingeniería" "dirección de la facultad" "ubicación"
mkintent Carreras    "qué carreras hay" "carreras de ingeniería" "qué puedo estudiar" "lista de carreras"
mkintent Inscripcion "cómo me inscribo" "requisitos de inscripción" "proceso de inscripción" "asignación de cursos"
mkintent Contacto    "teléfono de la facultad" "correo de contacto" "cómo los contacto" "contacto"

aws lexv2-models build-bot-locale --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE" >/dev/null
echo "Construyendo el bot..."
aws lexv2-models wait bot-locale-built --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE"

# ---- Version + alias con la Lambda ----
VER=$(aws lexv2-models create-bot-version --bot-id "$BOT_ID" \
  --bot-version-locale-specification "{\"$LOCALE\":{\"sourceBotVersion\":\"DRAFT\"}}" \
  --query botVersion --output text)
aws lexv2-models wait bot-version-available --bot-id "$BOT_ID" --bot-version "$VER"

aws lambda add-permission --function-name "$PROJ-lex-fulfillment" --statement-id lex-invoke \
  --action lambda:InvokeFunction --principal lexv2.amazonaws.com \
  --source-arn "arn:aws:lex:$AWS_REGION:$ACCOUNT_ID:bot-alias/$BOT_ID/*" >/dev/null

ALIAS_ID=$(aws lexv2-models create-bot-alias --bot-alias-name prod --bot-id "$BOT_ID" --bot-version "$VER" \
  --bot-alias-locale-settings "{\"$LOCALE\":{\"enabled\":true,\"codeHookSpecification\":{\"lambdaCodeHook\":{\"lambdaARN\":\"$LEX_LAMBDA_ARN\",\"codeHookInterfaceVersion\":\"1.0\"}}}}" \
  --query botAliasId --output text)
aws lexv2-models wait bot-alias-available --bot-id "$BOT_ID" --bot-alias-id "$ALIAS_ID"
save BOT_ALIAS_ID "$ALIAS_ID"

# Los backends leen estos IDs desde SSM
aws ssm put-parameter --name "$SSM_PREFIX/bot_id"       --type String --value "$BOT_ID"   --overwrite >/dev/null
aws ssm put-parameter --name "$SSM_PREFIX/bot_alias_id" --type String --value "$ALIAS_ID" --overwrite >/dev/null

echo "OK Lex  bot=$BOT_ID alias=$ALIAS_ID"
echo "Prueba: aws lexv2-runtime recognize-text --bot-id $BOT_ID --bot-alias-id $ALIAS_ID --locale-id $LOCALE --session-id t1 --text 'a qué hora abren'"
