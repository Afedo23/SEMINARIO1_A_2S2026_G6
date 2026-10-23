#!/usr/bin/env bash
# Semi-Social | Grupo 6 | variables comunes (se hace "source" desde cada script)
set -euo pipefail

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export GRP=6
export PROJ="semi-g6"

# Tamaños (se pueden sobreescribir exportando la variable antes de correr)
export INSTANCE_TYPE="${INSTANCE_TYPE:-c7i-flex.large}"   # alternativa barata: t3.small
export DB_CLASS="${DB_CLASS:-db.t3.micro}"
export DB_MULTI_AZ="${DB_MULTI_AZ:-true}"                  # false si tu cuenta no lo permite

export DB_NAME="semisocial"
export DB_USER="semiadmin"
# Los nombres de bucket son unicos en TODO AWS: si "semi1proyecto-g6" ya lo tiene otra cuenta,
# se agrega este sufijo. Para quitarlo:  export BUCKET_SUFFIX=
export BUCKET_SUFFIX="${BUCKET_SUFFIX--2s2026}"
export IMG_BUCKET="semi1proyecto-g${GRP}${BUCKET_SUFFIX}"
export WEB_BUCKET="proyecto-web-g${GRP}${BUCKET_SUFFIX}"   # S3 no admite mayusculas
export SSM_PREFIX="/semisocial/g${GRP}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ACCOUNT_ID

# Archivo donde se guardan los IDs creados (VPC, subnets, SG, endpoints...)
export STATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.state.env"
touch "$STATE"
# shellcheck disable=SC1090
source "$STATE"

# ---- Compatibilidad con Git Bash (Windows) ----
export MSYS_NO_PATHCONV=1      # evita que Git Bash reescriba argumentos como /semisocial/... o '/*'
export MSYS2_ARG_CONV_EXCL="*"
export AWS_PAGER=""            # sin paginador interactivo
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"            # carpeta de estos scripts
# Carpeta Proyecto = donde estan lambda/, db/, backend-*/ y frontend/ (junto a los scripts o un nivel arriba)
ROOT=""
for d in "$SD" "$SD/.." "$SD/../Proyecto"; do
  if [ -d "$d/lambda" ] || [ -d "$d/backend-node" ] || [ -d "$d/frontend" ]; then ROOT="$(cd "$d" && pwd)"; break; fi
done
[ -n "$ROOT" ] || ROOT="$SD"
need_dir() {  # need_dir <ruta> <nombre>
  [ -d "$1" ] || { echo "ERROR: no encuentro '$1'."; echo "Copia la carpeta '$2' (de lo que descargaste) junto a estos scripts, dentro de: $ROOT"; exit 1; }
}
export SD ROOT
# Los archivos que lee aws.exe (file://, fileb://) deben ir con ruta RELATIVA a esta carpeta
export T=".tmp"; mkdir -p "$SD/$T"
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys" >/dev/null 2>&1; then PY="$c"; break; fi
done
export PY

save() { echo "export $1=\"$2\"" >> "$STATE"; export "$1=$2"; }
