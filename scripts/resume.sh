#!/usr/bin/env bash
set -euo pipefail
export TF_IN_AUTOMATION=true

# -----------------------------
# Resume Hackathon Environment
# - Start RDS
# - Enable runtime resources (ALB + ECS services)
# -----------------------------

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_ENV_DIR="$ROOT_DIR/terraform/environments/dev"

AWS_REGION="us-east-1"
DB_IDENTIFIER="hackathon-postgres"

# Health check (ALB) validation
HEALTH_TIMEOUT_SECONDS=300
HEALTH_SLEEP_SECONDS=5

cd "$TF_ENV_DIR"

echo "==> Starting RDS instance: $DB_IDENTIFIER"
aws rds start-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION" \
  --no-cli-pager >/dev/null 2>&1 || echo "RDS already running or not available"

# Wait until the DB is available before enabling runtime
echo "==> Waiting for RDS to become available..."
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION" \
  --no-cli-pager || echo "RDS wait skipped (already available or not yet ready)"

echo "==> Initializing Terraform backend (S3)..."
terraform init -input=false -reconfigure

echo "==> Enabling runtime (ALB + ECS services)..."
terraform apply -auto-approve -var="runtime_enabled=true"

echo "==> Validating ALB health endpoints..."
UPLOAD_URL="$(terraform output -raw upload_health_url 2>/dev/null || true)"
DOWNLOAD_URL="$(terraform output -raw download_health_url 2>/dev/null || true)"

if [[ -z "$UPLOAD_URL" || -z "$DOWNLOAD_URL" ]]; then
  echo "==> Warning: health URLs are empty. Skipping health validation."
else
  deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  while [[ $SECONDS -lt $deadline ]]; do
    if curl -fsS "$UPLOAD_URL" >/dev/null 2>&1 && curl -fsS "$DOWNLOAD_URL" >/dev/null 2>&1; then
      echo "==> Upload OK:   $UPLOAD_URL"
      echo "==> Download OK: $DOWNLOAD_URL"
      break
    fi
    echo "==> Waiting for services to become healthy..."
    sleep "$HEALTH_SLEEP_SECONDS"
  done

  if [[ $SECONDS -ge $deadline ]]; then
    echo "==> Warning: services did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s."
    echo "==> Upload URL:   $UPLOAD_URL"
    echo "==> Download URL: $DOWNLOAD_URL"
  fi
fi

echo "==> Environment resumed successfully."