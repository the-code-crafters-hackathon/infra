#!/usr/bin/env bash
set -euo pipefail

POOL='us-east-1_gKewx3jR6'
CLIENT='5i9t3alfps0ing51ehvpvqfpov'
ALB='http://hackathon-alb-697433696.us-east-1.elb.amazonaws.com'
USER="smoke$(date +%s)@example.com"
PASS='Hackathon#2026Aa'

AWS_PAGER='' aws cognito-idp admin-create-user \
  --user-pool-id "$POOL" \
  --username "$USER" \
  --user-attributes Name=email,Value="$USER" Name=email_verified,Value=true \
  --message-action SUPPRESS >/dev/null

AWS_PAGER='' aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL" \
  --username "$USER" \
  --password "$PASS" \
  --permanent >/dev/null

TOKEN=$(AWS_PAGER='' aws cognito-idp initiate-auth \
  --client-id "$CLIENT" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$USER,PASSWORD=$PASS" \
  --query 'AuthenticationResult.IdToken' \
  --output text)

echo "TOKEN_LEN=${#TOKEN}"

ffmpeg -loglevel error -f lavfi -i color=c=blue:s=320x240:d=2 -pix_fmt yuv420p /tmp/smoke-auth.mp4 -y

echo '--- upload no auth (expect 401) ---'
curl -s -i -X POST "$ALB/upload/video" \
  -F 'user_id=99' -F 'title=smoke-auth' -F 'file=@/tmp/smoke-auth.mp4;type=video/mp4' | sed -n '1,2p'

echo '--- upload with auth ---'
UPLOAD_RESP=$(curl -s -H "Authorization: Bearer $TOKEN" -X POST "$ALB/upload/video" \
  -F 'user_id=99' -F 'title=smoke-auth' -F 'file=@/tmp/smoke-auth.mp4;type=video/mp4')

echo "$UPLOAD_RESP" | sed -n '1,3p'
VIDEO_ID=$(echo "$UPLOAD_RESP" | jq -r '.data.id // empty')
if [[ -z "$VIDEO_ID" ]]; then
  echo 'ERROR: sem video id'
  exit 1
fi

echo "VIDEO_ID=$VIDEO_ID"

DEADLINE=$(( $(date +%s) + 300 ))
STATUS=''
FILE_PATH=''
while [[ $(date +%s) -lt "$DEADLINE" ]]; do
  LIST_RESP=$(curl -s -H "Authorization: Bearer $TOKEN" "$ALB/upload/videos/99")
  STATUS=$(echo "$LIST_RESP" | jq -r --argjson ID "$VIDEO_ID" '.data[]? | select(.id==$ID) | .status // empty')
  FILE_PATH=$(echo "$LIST_RESP" | jq -r --argjson ID "$VIDEO_ID" '.data[]? | select(.id==$ID) | .file_path // empty')
  if [[ "$STATUS" == "1" ]]; then
    break
  fi
  sleep 10
done

echo "FINAL_STATUS=${STATUS:-none}"
echo "FINAL_FILE_PATH=${FILE_PATH:-none}"

echo '--- download with auth ---'
curl -s -i -H "Authorization: Bearer $TOKEN" "$ALB/download/videos/99" | sed -n '1,12p'
