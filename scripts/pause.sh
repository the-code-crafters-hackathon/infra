#!/usr/bin/env bash
set -euo pipefail
export TF_IN_AUTOMATION=true

# -----------------------------
# Pause Hackathon Environment
# - Disable runtime resources (ALB + ECS services)
# - Stop RDS to reduce costs
# -----------------------------

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_ENV_DIR="$ROOT_DIR/terraform/environments/dev"

AWS_REGION="us-east-1"
DB_IDENTIFIER="hackathon-postgres"

get_db_status() {
  aws rds describe-db-instances \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --region "$AWS_REGION" \
    --query "DBInstances[0].DBInstanceStatus" \
    --output text 2>/dev/null || echo "unknown"
}

cd "$TF_ENV_DIR"

echo "==> Pausing runtime (ALB + ECS services)..."
terraform apply -auto-approve -var="runtime_enabled=false"

echo "==> Checking RDS state: $DB_IDENTIFIER"
DB_STATUS="$(get_db_status)"
echo "==> RDS status: ${DB_STATUS}"

if [[ "$DB_STATUS" == "available" ]]; then
  echo "==> Stopping RDS instance: $DB_IDENTIFIER"
  aws rds stop-db-instance \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --region "$AWS_REGION"
  echo "==> Stop requested. Current status may transition to 'stopping'."
elif [[ "$DB_STATUS" == "stopping" || "$DB_STATUS" == "stopped" ]]; then
  echo "==> RDS is already ${DB_STATUS}. Nothing to do."
else
  echo "==> RDS is in state '${DB_STATUS}'. Skipping stop to avoid InvalidDBInstanceState."
fi

echo "==> Environment paused successfully."
