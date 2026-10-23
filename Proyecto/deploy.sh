#!/usr/bin/env bash
# Semi-Social G6 - crea la infraestructura base (pasos 01 a 08) en orden.
#   export DB_PASS='UnaClaveSegura123'
#   bash deploy.sh          # desde el paso 01
#   bash deploy.sh 03       # continua desde el paso 03 (los IDs previos estan en .state.env)
# Si un paso falla, corrige y vuelve a correr SOLO ese script (o: bash deploy.sh NN).
set -euo pipefail
cd "$(dirname "$0")"
: "${DB_PASS:?Exporta DB_PASS primero}"
START="${1:-01}"

for s in 01-network 02-iam 03-storage 04-database 05-cognito 06-compute 07-serverless 08-lex; do
  [[ "${s%%-*}" < "$START" ]] && continue
  echo; echo "================ $s ================"
  bash "./$s.sh"
done
echo; echo "Infraestructura lista. Ver IDs y endpoints en .state.env"
