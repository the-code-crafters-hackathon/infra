#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

POOL="${POOL:-us-east-1_gKewx3jR6}"
CLIENT="${CLIENT:-5i9t3alfps0ing51ehvpvqfpov}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ALB="${ALB:-}"
ALB_NAME="${ALB_NAME:-hackathon-alb}"
ECS_CLUSTER_NAME="${ECS_CLUSTER_NAME:-hackathon-cluster}"
ECS_UPLOAD_SERVICE_NAME="${ECS_UPLOAD_SERVICE_NAME:-hackathon-upload}"
USER_ID="${USER_ID:-99}"
PASS="${PASS:-Hackathon#2026Aa}"
COGNITO_USERNAME="${COGNITO_USERNAME:-smoke$(date +%s)@example.com}"
VIDEO_FILE="${VIDEO_FILE:-}"
VIDEO_CONTENT_TYPE="${VIDEO_CONTENT_TYPE:-}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/outputs}"
INPUT_DIR="${INPUT_DIR:-$ROOT_DIR/inputs}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_FILE="${OUTPUT_FILE:-$OUTPUT_DIR/smoke-e2e-auth-full-flow_${TIMESTAMP}.out}"
SUMMARY_FILE="${SUMMARY_FILE:-$OUTPUT_DIR/smoke-e2e-auth-full-flow_${TIMESTAMP}.summary.txt}"

mkdir -p "$OUTPUT_DIR"

if [[ "${DISABLE_TEE:-false}" != "true" ]]; then
  exec > >(tee -a "$OUTPUT_FILE") 2>&1
fi

echo "[INFO] Iniciando smoke E2E auth full flow"
echo "[INFO] Log: $OUTPUT_FILE"
echo "[INFO] Resumo: $SUMMARY_FILE"

if [[ "$COGNITO_USERNAME" != *"@"* ]]; then
  echo "[ERRO] COGNITO_USERNAME deve ser um e-mail válido. Valor atual: $COGNITO_USERNAME"
  exit 2
fi

for cmd in aws curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERRO] Comando obrigatório não encontrado: $cmd"
    exit 2
  fi
done

if [[ -z "$VIDEO_FILE" ]]; then
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "[ERRO] ffmpeg é obrigatório quando VIDEO_FILE não é informado"
    exit 2
  fi
fi

if ! AWS_PAGER='' aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[ERRO] AWS CLI sem credenciais válidas para execução do smoke"
  exit 2
fi

resolve_alb_dns_from_ecs() {
  local tg_arn=""
  local lb_arn=""
  local dns=""

  tg_arn=$(AWS_PAGER='' aws ecs describe-services \
    --cluster "$ECS_CLUSTER_NAME" \
    --services "$ECS_UPLOAD_SERVICE_NAME" \
    --region "$AWS_REGION" \
    --query 'services[0].loadBalancers[0].targetGroupArn' \
    --output text 2>/dev/null || true)

  if [[ -z "$tg_arn" || "$tg_arn" == "None" ]]; then
    return 1
  fi

  lb_arn=$(AWS_PAGER='' aws elbv2 describe-target-groups \
    --target-group-arns "$tg_arn" \
    --region "$AWS_REGION" \
    --query 'TargetGroups[0].LoadBalancerArns[0]' \
    --output text 2>/dev/null || true)

  if [[ -z "$lb_arn" || "$lb_arn" == "None" ]]; then
    return 1
  fi

  dns=$(AWS_PAGER='' aws elbv2 describe-load-balancers \
    --load-balancer-arns "$lb_arn" \
    --region "$AWS_REGION" \
    --query 'LoadBalancers[0].DNSName' \
    --output text 2>/dev/null || true)

  if [[ -z "$dns" || "$dns" == "None" ]]; then
    return 1
  fi

  echo "$dns"
  return 0
}

if [[ -z "$ALB" ]]; then
  if resolved_dns=$(resolve_alb_dns_from_ecs); then
    ALB="http://${resolved_dns}"
  else
    fallback_dns=$(AWS_PAGER='' aws elbv2 describe-load-balancers \
      --names "$ALB_NAME" \
      --region "$AWS_REGION" \
      --query 'LoadBalancers[0].DNSName' \
      --output text 2>/dev/null || true)

    if [[ -n "$fallback_dns" && "$fallback_dns" != "None" ]]; then
      ALB="http://${fallback_dns}"
    fi
  fi
fi

if [[ -z "$ALB" ]]; then
  echo "[ERRO] Não foi possível resolver ALB automaticamente. Informe ALB=http://<dns-do-alb>"
  exit 2
fi

echo "[INFO] Base URL: $ALB"

AWS_PAGER='' aws cognito-idp admin-create-user \
  --user-pool-id "$POOL" \
  --username "$COGNITO_USERNAME" \
  --user-attributes Name=email,Value="$COGNITO_USERNAME" Name=email_verified,Value=true \
  --message-action SUPPRESS >/dev/null

AWS_PAGER='' aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL" \
  --username "$COGNITO_USERNAME" \
  --password "$PASS" \
  --permanent >/dev/null

TOKEN=$(AWS_PAGER='' aws cognito-idp initiate-auth \
  --client-id "$CLIENT" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$COGNITO_USERNAME,PASSWORD=$PASS" \
  --query 'AuthenticationResult.IdToken' \
  --output text)

echo "TOKEN_LEN=${#TOKEN}"

UPLOAD_INPUT_FILE="$VIDEO_FILE"
if [[ -z "$UPLOAD_INPUT_FILE" && -d "$INPUT_DIR" ]]; then
  for candidate in "$INPUT_DIR"/*; do
    [[ -f "$candidate" ]] || continue
    case "${candidate##*.}" in
      mp4|MP4|avi|AVI|mov|MOV|mkv|MKV|wmv|WMV|flv|FLV|webm|WEBM)
        UPLOAD_INPUT_FILE="$candidate"
        break
        ;;
    esac
  done
fi

if [[ -z "$UPLOAD_INPUT_FILE" ]]; then
  UPLOAD_INPUT_FILE="/tmp/smoke-auth.mp4"
  ffmpeg -loglevel error -f lavfi -i color=c=blue:s=320x240:d=2 -pix_fmt yuv420p "$UPLOAD_INPUT_FILE" -y
fi

if [[ ! -f "$UPLOAD_INPUT_FILE" ]]; then
  echo "[ERRO] VIDEO_FILE não encontrado: $UPLOAD_INPUT_FILE"
  exit 2
fi

if [[ -z "$VIDEO_CONTENT_TYPE" ]]; then
  case "${UPLOAD_INPUT_FILE##*.}" in
    mp4|MP4) VIDEO_CONTENT_TYPE="video/mp4" ;;
    avi|AVI) VIDEO_CONTENT_TYPE="video/x-msvideo" ;;
    mov|MOV) VIDEO_CONTENT_TYPE="video/quicktime" ;;
    mkv|MKV) VIDEO_CONTENT_TYPE="video/x-matroska" ;;
    wmv|WMV) VIDEO_CONTENT_TYPE="video/x-ms-wmv" ;;
    flv|FLV) VIDEO_CONTENT_TYPE="video/x-flv" ;;
    webm|WEBM) VIDEO_CONTENT_TYPE="video/webm" ;;
    *) VIDEO_CONTENT_TYPE="video/mp4" ;;
  esac
fi

echo "[INFO] Arquivo de upload: $UPLOAD_INPUT_FILE"
echo "[INFO] Content-Type de upload: $VIDEO_CONTENT_TYPE"

echo '--- upload no auth (expect 401) ---'
UNAUTH_BODY="$OUTPUT_DIR/.unauth_upload_${TIMESTAMP}.json"
UPLOAD_NO_AUTH_CODE=$(curl -s -o "$UNAUTH_BODY" -w '%{http_code}' -X POST "$ALB/upload/video" \
  -F "user_id=${USER_ID}" -F 'title=smoke-auth' -F "file=@${UPLOAD_INPUT_FILE};type=${VIDEO_CONTENT_TYPE}")
echo "UPLOAD_NO_AUTH_CODE=$UPLOAD_NO_AUTH_CODE"
if [[ "$UPLOAD_NO_AUTH_CODE" != "401" ]]; then
  echo "[ERRO] Esperado 401 sem token, mas retornou $UPLOAD_NO_AUTH_CODE"
  cat "$UNAUTH_BODY"
  exit 1
fi

echo '--- upload with auth ---'
UPLOAD_RESP=$(curl -s -H "Authorization: Bearer $TOKEN" -X POST "$ALB/upload/video" \
  -F "user_id=${USER_ID}" -F 'title=smoke-auth' -F "file=@${UPLOAD_INPUT_FILE};type=${VIDEO_CONTENT_TYPE}")

UPLOAD_CODE=$(echo "$UPLOAD_RESP" | jq -r '.status // empty')
VIDEO_ID=$(echo "$UPLOAD_RESP" | jq -r '.data.id // empty')
UPLOAD_FILE_PATH=$(echo "$UPLOAD_RESP" | jq -r '.data.file_path // empty')
if [[ -z "$VIDEO_ID" ]]; then
  echo 'ERROR: sem video id'
  echo "$UPLOAD_RESP"
  exit 1
fi

echo "UPLOAD_CODE=${UPLOAD_CODE:-unknown}"
echo "VIDEO_ID=$VIDEO_ID"
echo "UPLOAD_FILE_PATH=${UPLOAD_FILE_PATH:-none}"

DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))
STATUS=''
FILE_PATH=''
while [[ $(date +%s) -lt "$DEADLINE" ]]; do
  LIST_RESP=$(curl -s -H "Authorization: Bearer $TOKEN" "$ALB/upload/videos/${USER_ID}")
  STATUS=$(echo "$LIST_RESP" | jq -r --argjson ID "$VIDEO_ID" '.data[]? | select(.id==$ID) | .status // empty')
  FILE_PATH=$(echo "$LIST_RESP" | jq -r --argjson ID "$VIDEO_ID" '.data[]? | select(.id==$ID) | .file_path // empty')
  if [[ "$STATUS" == "1" ]]; then
    break
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

echo "FINAL_STATUS=${STATUS:-none}"
echo "FINAL_FILE_PATH=${FILE_PATH:-none}"

if [[ "${STATUS:-}" != "1" ]]; then
  echo "[ERRO] Timeout aguardando status final=1"
  exit 1
fi

echo '--- download with auth ---'
DOWNLOAD_BODY="$OUTPUT_DIR/.download_${TIMESTAMP}.json"
DOWNLOAD_CODE=$(curl -s -o "$DOWNLOAD_BODY" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$ALB/download/videos/${USER_ID}")
if [[ "$DOWNLOAD_CODE" != "200" ]]; then
  echo "[ERRO] Download/lista autenticada retornou $DOWNLOAD_CODE"
  cat "$DOWNLOAD_BODY"
  exit 1
fi

DOWNLOAD_STATUS=$(jq -r '.status // empty' "$DOWNLOAD_BODY")
DOWNLOAD_COUNT=$(jq -r '(.data // []) | length' "$DOWNLOAD_BODY")
echo "DOWNLOAD_CODE=$DOWNLOAD_CODE"
echo "DOWNLOAD_STATUS=${DOWNLOAD_STATUS:-unknown}"
echo "DOWNLOAD_ITEMS=$DOWNLOAD_COUNT"

cat > "$SUMMARY_FILE" <<EOF
SMOKE_E2E_AUTH_FULL_FLOW=PASS
TIMESTAMP=$TIMESTAMP
BASE_URL=$ALB
COGNITO_USERNAME=$COGNITO_USERNAME
UPLOAD_NO_AUTH_CODE=$UPLOAD_NO_AUTH_CODE
UPLOAD_CODE=${UPLOAD_CODE:-unknown}
VIDEO_ID=$VIDEO_ID
FINAL_STATUS=${STATUS:-none}
FINAL_FILE_PATH=${FILE_PATH:-none}
DOWNLOAD_CODE=$DOWNLOAD_CODE
DOWNLOAD_STATUS=${DOWNLOAD_STATUS:-unknown}
DOWNLOAD_ITEMS=$DOWNLOAD_COUNT
RAW_LOG=$OUTPUT_FILE
EOF

rm -f "$UNAUTH_BODY" "$DOWNLOAD_BODY"

echo "[OK] Smoke E2E auth full flow concluído com sucesso"
echo "[OK] Evidências resumidas em: $SUMMARY_FILE"
