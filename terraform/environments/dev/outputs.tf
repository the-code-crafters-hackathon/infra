############################################
# Outputs - Network baseline (No NAT)
############################################

output "aws_region" {
  description = "AWS region for this environment"
  value       = var.aws_region
}

output "prefix" {
  description = "Resource naming prefix"
  value       = var.prefix
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB + ECS tasks with public IP)"
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs (RDS)"
  value       = [for s in aws_subnet.private : s.id]
}

output "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks"
  value       = [for s in aws_subnet.public : s.cidr_block]
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks"
  value       = [for s in aws_subnet.private : s.cidr_block]
}

output "sg_alb_id" {
  description = "Security Group ID for the ALB"
  value       = aws_security_group.alb.id
}

output "sg_api_id" {
  description = "Security Group ID for Upload/Download ECS tasks"
  value       = aws_security_group.api.id
}

output "sg_worker_id" {
  description = "Security Group ID for Processor ECS task"
  value       = aws_security_group.worker.id
}

output "sg_rds_id" {
  description = "Security Group ID for RDS Postgres"
  value       = aws_security_group.rds.id
}

output "public_route_table_id" {
  description = "Public route table ID (0.0.0.0/0 -> IGW)"
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "Private route table ID (no internet route; no NAT)"
  value       = aws_route_table.private.id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.this.id
}

############################################
# Outputs - RDS Postgres
############################################

output "db_endpoint" {
  description = "RDS endpoint address"
  value       = aws_db_instance.hackathon.address
}

output "db_port" {
  description = "RDS port"
  value       = aws_db_instance.hackathon.port
}

output "db_name" {
  description = "Database name"
  value       = var.db_name
}

output "db_secret_arn" {
  description = "Secrets Manager secret ARN for DB credentials"
  value       = aws_secretsmanager_secret.db.arn
}

############################################
# Outputs - SQS
############################################

output "jobs_queue_url" {
  description = "SQS Jobs Queue URL"
  value       = aws_sqs_queue.jobs.url
}

output "jobs_queue_arn" {
  description = "SQS Jobs Queue ARN"
  value       = aws_sqs_queue.jobs.arn
}

output "jobs_dlq_url" {
  description = "SQS Dead Letter Queue URL"
  value       = aws_sqs_queue.jobs_dlq.url
}

output "jobs_dlq_arn" {
  description = "SQS Dead Letter Queue ARN"
  value       = aws_sqs_queue.jobs_dlq.arn
}

############################################
# Outputs - SNS
############################################

output "processing_alerts_topic_arn" {
  description = "SNS topic ARN for processing failure alerts"
  value       = aws_sns_topic.processing_alerts.arn
}

############################################
# Outputs - S3
############################################

output "media_bucket_name" {
  description = "S3 bucket for input/output artifacts"
  value       = aws_s3_bucket.media.bucket
}

output "media_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.media.arn
}

output "media_input_prefix" {
  description = "Logical prefix for input objects (S3 uses prefixes, not real folders)"
  value       = "input/"
}

output "media_output_prefix" {
  description = "Logical prefix for output objects (S3 uses prefixes, not real folders)"
  value       = "output/"
}

############################################
# Outputs - ECR
############################################

output "ecr_upload_repo_url" {
  description = "ECR repository URL for upload-service"
  value       = aws_ecr_repository.upload.repository_url
}

output "ecr_download_repo_url" {
  description = "ECR repository URL for download-service"
  value       = aws_ecr_repository.download.repository_url
}

output "ecr_processor_repo_url" {
  description = "ECR repository URL for processor-service"
  value       = aws_ecr_repository.processor.repository_url
}

############################################
# Outputs - Cognito
############################################

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.this.id
}

output "cognito_user_pool_client_id" {
  description = "Cognito App Client ID"
  value       = aws_cognito_user_pool_client.this.id
}

output "cognito_issuer_url" {
  description = "JWT issuer URL (iss) used for token validation"
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
}

output "cognito_jwks_url" {
  description = "JWKS URL for JWT signature validation"
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}/.well-known/jwks.json"
}


############################################
# Outputs - CloudWatch Logs
############################################

output "log_group_upload" {
  description = "CloudWatch Log Group for upload service"
  value       = aws_cloudwatch_log_group.upload.name
}

output "log_group_download" {
  description = "CloudWatch Log Group for download service"
  value       = aws_cloudwatch_log_group.download.name
}

output "log_group_processor" {
  description = "CloudWatch Log Group for processor service"
  value       = aws_cloudwatch_log_group.processor.name
}


############################################
# Outputs - ECS
############################################

output "ecs_cluster_name" {
  description = "ECS Cluster name for the hackathon environment"
  value       = aws_ecs_cluster.this.name
}

output "ecs_cluster_arn" {
  description = "ECS Cluster ARN for the hackathon environment"
  value       = aws_ecs_cluster.this.arn
}

############################################
# Outputs - IAM (ECS Roles)
############################################

output "ecs_task_execution_role_name" {
  description = "ECS execution role name (ECR pull, logs, secrets injection)"
  value       = aws_iam_role.ecs_task_execution.name
}

output "ecs_task_execution_role_arn" {
  description = "ECS task execution role ARN"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_role_name" {
  description = "ECS application role name (runtime access for the application)"
  value       = aws_iam_role.ecs_task.name
}

output "ecs_task_role_arn" {
  description = "ECS task role ARN"
  value       = aws_iam_role.ecs_task.arn
}

############################################
# Outputs - ECS Task Definitions
############################################

output "ecs_taskdef_upload_family" {
  description = "ECS task definition family for upload service"
  value       = aws_ecs_task_definition.upload.family
}

output "ecs_taskdef_upload_arn" {
  description = "ECS task definition ARN for upload service"
  value       = aws_ecs_task_definition.upload.arn
}

output "ecs_taskdef_download_family" {
  description = "ECS task definition family for download service"
  value       = aws_ecs_task_definition.download.family
}

output "ecs_taskdef_download_arn" {
  description = "ECS task definition ARN for download service"
  value       = aws_ecs_task_definition.download.arn
}

output "ecs_taskdef_processor_family" {
  description = "ECS task definition family for processor service"
  value       = aws_ecs_task_definition.processor.family
}

output "ecs_taskdef_processor_arn" {
  description = "ECS task definition ARN for processor service"
  value       = aws_ecs_task_definition.processor.arn
}

############################################
# Outputs - ALB / Runtime
############################################

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer"
  value       = var.runtime_enabled ? aws_lb.this[0].dns_name : null
}

output "upload_health_url" {
  description = "Convenience URL for upload health check"
  value       = var.runtime_enabled ? "http://${aws_lb.this[0].dns_name}/health" : null
}

output "download_health_url" {
  description = "Convenience URL for download health check"
  value       = var.runtime_enabled ? "http://${aws_lb.this[0].dns_name}/download/health" : null
}

output "ecs_service_upload_name" {
  description = "ECS service name for upload"
  value       = var.runtime_enabled ? aws_ecs_service.upload[0].name : null
}

output "ecs_service_download_name" {
  description = "ECS service name for download"
  value       = var.runtime_enabled ? aws_ecs_service.download[0].name : null
}

output "ecs_service_processor_name" {
  description = "ECS service name for processor"
  value       = aws_ecs_service.processor.name
}

############################################
# Outputs - GitHub Actions OIDC
############################################

output "github_actions_role_arn" {
  description = "IAM role ARN to be assumed by GitHub Actions via OIDC"
  value       = aws_iam_role.github_actions_infra.arn
}

output "github_actions_apps_deploy_role_arn" {
  description = "IAM role ARN to be assumed by GitHub Actions (application repos) via OIDC for deploy (ECR/ECS)"
  value       = aws_iam_role.github_actions_apps_deploy.arn
}

output "github_actions_oidc_provider_arn" {
  description = "OIDC provider ARN (token.actions.githubusercontent.com)"
  value       = aws_iam_openid_connect_provider.github.arn
}