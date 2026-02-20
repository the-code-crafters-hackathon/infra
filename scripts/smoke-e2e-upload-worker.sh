#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ALB_NAME="${ALB_NAME:-hackathon-alb}"
ALB_DNS="${ALB_DNS:-}"
ECS_CLUSTER_NAME="${ECS_CLUSTER_NAME:-hackathon-cluster}"
ECS_UPLOAD_SERVICE_NAME="${ECS_UPLOAD_SERVICE_NAME:-hackathon-upload}"
UPLOAD_USER_ID="${UPLOAD_USER_ID:-99}"
UPLOAD_TITLE="${UPLOAD_TITLE:-smoke-e2e-video}"
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-180}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-6}"

if ! command -v curl >/dev/null 2>&1; then
  echo "[ERRO] curl não encontrado no PATH"
  exit 2
fi
if ! command -v aws >/dev/null 2>&1; then
  echo "[ERRO] aws cli não encontrada no PATH"
  exit 2
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "[ERRO] ffmpeg não encontrado no PATH"
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERRO] python3 não encontrado no PATH"
  exit 2
fi

resolve_alb_dns_from_ecs() {
  local tg_arn=""
  local lb_arn=""
  local dns=""

  tg_arn=$(aws ecs describe-services \
    --cluster "$ECS_CLUSTER_NAME" \
    --services "$ECS_UPLOAD_SERVICE_NAME" \
    --region "$AWS_REGION" \
    --query 'services[0].loadBalancers[0].targetGroupArn' \
    --output text 2>/dev/null || true)

  if [[ -z "$tg_arn" || "$tg_arn" == "None" ]]; then
    return 1
  fi

  lb_arn=$(aws elbv2 describe-target-groups \
    --target-group-arns "$tg_arn" \
    --region "$AWS_REGION" \
    --query 'TargetGroups[0].LoadBalancerArns[0]' \
    --output text 2>/dev/null || true)

  if [[ -z "$lb_arn" || "$lb_arn" == "None" ]]; then
    return 1
  fi

  dns=$(aws elbv2 describe-load-balancers \
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

if [[ -z "$ALB_DNS" ]]; then
  if resolved_dns=$(resolve_alb_dns_from_ecs); then
    ALB_DNS="$resolved_dns"
  else
    ALB_DNS=$(aws elbv2 describe-load-balancers \
      --names "$ALB_NAME" \
      --region "$AWS_REGION" \
      --query 'LoadBalancers[0].DNSName' \
      --output text)
  fi
fi

if [[ -z "$ALB_DNS" || "$ALB_DNS" == "None" ]]; then
  echo "[ERRO] Não foi possível resolver ALB_DNS (ALB_NAME=$ALB_NAME, ECS_CLUSTER_NAME=$ECS_CLUSTER_NAME, ECS_UPLOAD_SERVICE_NAME=$ECS_UPLOAD_SERVICE_NAME)"
  exit 2
fi

BASE_URL="http://${ALB_DNS}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

VIDEO_FILE="$WORK_DIR/e2e.mp4"
UPLOAD_RESPONSE="$WORK_DIR/upload_response.json"
LIST_RESPONSE="$WORK_DIR/list_response.json"

ffmpeg -loglevel error -f lavfi -i testsrc=size=640x360:rate=30 -t 2 -pix_fmt yuv420p -y "$VIDEO_FILE"

echo "[INFO] Base URL: $BASE_URL"

HEALTH_CODE=$(curl -sS -o "$WORK_DIR/health.json" -w '%{http_code}' "$BASE_URL/health/")
if [[ "$HEALTH_CODE" != "200" ]]; then
  echo "[ERRO] Health check falhou com status $HEALTH_CODE"
  cat "$WORK_DIR/health.json"
  exit 1
fi

UPLOAD_CODE=$(curl -sS -o "$UPLOAD_RESPONSE" -w '%{http_code}' \
  -X POST "$BASE_URL/upload/video" \
  -F "user_id=${UPLOAD_USER_ID}" \
  -F "title=${UPLOAD_TITLE}" \
  -F "file=@${VIDEO_FILE};type=video/mp4")

if [[ "$UPLOAD_CODE" != "201" ]]; then
  echo "[ERRO] Upload falhou com status $UPLOAD_CODE"
  cat "$UPLOAD_RESPONSE"
  exit 1
fi

VIDEO_ID=$(python3 - "$UPLOAD_RESPONSE" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)

print(data.get('data', {}).get('id', ''))
PY
)

if [[ -z "$VIDEO_ID" ]]; then
  echo "[ERRO] Não foi possível extrair video_id da resposta de upload"
  cat "$UPLOAD_RESPONSE"
  exit 1
fi

echo "[INFO] Upload realizado com sucesso. video_id=$VIDEO_ID"

deadline=$((SECONDS + POLL_TIMEOUT_SECONDS))
processed="false"

while [[ $SECONDS -lt $deadline ]]; do
  LIST_CODE=$(curl -sS -o "$LIST_RESPONSE" -w '%{http_code}' "$BASE_URL/upload/videos/${UPLOAD_USER_ID}")

  if [[ "$LIST_CODE" != "200" ]]; then
    echo "[WARN] Listagem retornou status $LIST_CODE; tentando novamente..."
    sleep "$POLL_INTERVAL_SECONDS"
    continue
  fi

  status_result=$(python3 - "$LIST_RESPONSE" "$VIDEO_ID" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    payload = json.load(f)
video_id = int(sys.argv[2])

for item in payload.get('data', []):
    if item.get('id') == video_id:
        status = item.get('status')
        file_path = item.get('file_path', '')
        print(f"{status}|{file_path}")
        break
else:
    print("NOT_FOUND|")
PY
)

  current_status="${status_result%%|*}"
  current_file_path="${status_result#*|}"

  if [[ "$current_status" == "1" ]]; then
    echo "[OK] Processamento concluído. video_id=$VIDEO_ID file_path=$current_file_path"
    processed="true"
    break
  fi

  if [[ "$current_status" == "2" ]]; then
    echo "[ERRO] Processamento retornou status=2 (erro)."
    cat "$LIST_RESPONSE"
    exit 1
  fi

  echo "[INFO] Aguardando processamento... status atual=${current_status}"
  sleep "$POLL_INTERVAL_SECONDS"
done

if [[ "$processed" != "true" ]]; then
  echo "[ERRO] Timeout aguardando processamento para video_id=$VIDEO_ID"
  cat "$LIST_RESPONSE"
  exit 1
fi

echo "[OK] Smoke E2E Upload -> Worker concluído com sucesso"
