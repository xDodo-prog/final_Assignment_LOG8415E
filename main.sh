#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"

# ===============================
# Utils
# ===============================
log() { printf "\n\033[1m[%-5s]\033[0m %s\n" "$1" "$2"; }

detect_python() {
  if command -v python3 >/dev/null 2>&1; then echo "python3"
  elif command -v py >/dev/null 2>&1; then echo "py -3"
  elif command -v python >/dev/null 2>&1; then echo "python"
  else echo ""; fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] '$1' non trouvé"; exit 1; }
}

wait_for_http() {
  local url="$1" retries="${2:-60}" delay="${3:-2}"
  for _ in $(seq 1 "$retries"); do
    if curl -fsS "$url" >/dev/null 2>&1; then return 0; fi
    sleep "$delay"
  done
  return 1
}

# ===============================
# Binaries & scripts
# ===============================
PYTHON_BIN="${PYTHON_BIN:-$(detect_python)}"
AWS_PY="${AWS_PY:-VPC_architecture.py}"
BENCH_PY="${BENCH_PY:-benchmark.py}"

[ -n "$PYTHON_BIN" ] || { echo "[ERROR] Python introuvable"; exit 1; }
for f in "$AWS_PY"; do
  [ -f "$f" ] || { echo "[ERROR] Script introuvable: $f"; exit 1; }
done

require_cmd curl
require_cmd aws

# ===============================
# Reading / Writing to .env
# ===============================
demande_input(){
  local prompt="$1" var
  while true; do
    read -p "$prompt: " var
    if [ -n "$var" ]; then echo "$var"; return
    else echo "This field is required"; fi
  done
}

if [ ! -s "$ENV_FILE" ]; then
  aws_access_key_id=$(demande_input "aws_access_key_id")
  aws_secret_access_key=$(demande_input "aws_secret_access_key")
  aws_session_token=$(demande_input "aws_session_token")
  ubuntu_ami_id=''
  key_name=''

  # remove old lines if they already exist
  sed -i '/^UBUNTU_AMI_ID=/d;/^aws_access_key_id=/d;/^aws_secret_access_key=/d;/^aws_session_token=/d;/^INSTANCE_NUMBER=/d' "$ENV_FILE" 2>/dev/null || true

  cat >> "$ENV_FILE" <<EOF
aws_access_key_id=$aws_access_key_id
aws_secret_access_key=$aws_secret_access_key
aws_session_token=$aws_session_token
UBUNTU_AMI_ID=$ubuntu_ami_id
KEY_NAME=$key_name
EOF

fi

if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-log8415e-a1}"
APP_PORT="${APP_PORT:-8000}"

# ===============================
# 1/3 Create
# ===============================

log STEP "1/3 - create"
"$PYTHON_BIN" "$AWS_PY" create

echo "[INFO] Waiting 60 seconds before deployment"
for i in {60..1}; do
  printf "\r %02d seconds remaining..." "$i"
  sleep 1
done
echo -e "\n[INFO] Resuming script."

# ===============================
# 2/3 Deploy
# ===============================
log STEP "2/3 - deploy"
$PYTHON_BIN "$AWS_PY" deploy


echo "[INFO] Waiting 60 seconds before the deployment of the application"
for i in {60..1}; do
  printf "\r %02d seconds remaining" "$i"
  sleep 1
done
echo -e "\n[INFO] Resuming script."

# ===============================
# 3/3 Benchmark
# ===============================
echo "[INFO] Waiting 60 seconds before the benchmarking"
for i in {60..1}; do
  printf "\r %02d seconds remaining" "$i"
  sleep 1
done
echo -e "\n[INFO] Benchmark started."

log STEP "3/3 - benchmark"
$PYTHON_BIN "$BENCH_PY"

# ===============================
# Option: resource destruction
# ===============================
read -p $'\nDo you want to destroy all the AWS instances that were created? (y/n) ' answer
case "$answer" in
  [Yy]*)
    log WARN "Destroying all resources..."
    "$PYTHON_BIN" "$AWS_PY" destroy
    log OK "All resources have been deleted."
    ;;
  *)
    log INFO "Instances retained. End of script."
    ;;
esac