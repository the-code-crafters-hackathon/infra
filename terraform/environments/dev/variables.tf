variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "prefix" {
  type    = string
  default = "hackathon"
}

variable "db_name" {
  type    = string
  default = "hackathon"
}

############################
# Database (RDS Postgres) - Hackathon
############################

variable "db_username" {
  type        = string
  description = "Master username for the Postgres instance"
  default     = "hackathon"
}

variable "db_password" {
  type        = string
  description = "Master password for the Postgres instance (opcional; se null, usa o valor já existente no Secrets Manager)"
  sensitive   = true
  default     = null
}

variable "db_instance_class" {
  type        = string
  description = "RDS instance class"
  default     = "db.t3.micro"
}

variable "db_allocated_storage_gb" {
  type        = number
  description = "Allocated storage for RDS in GB"
  default     = 20
}

variable "db_backup_retention_days" {
  type        = number
  description = "Backup retention (days) - keep low for hackathon"
  default     = 1
}

############################
# Runtime toggle (cost control)
# - When false, runtime resources (ALB + Upload/Download ECS services) are removed
############################

variable "runtime_enabled" {
  type        = bool
  description = "Enable runtime resources (ALB + Upload/Download ECS services). Set false to pause and reduce costs."
  default     = true
}

variable "upload_image_tag" {
  type        = string
  description = "Container image tag for upload-service in ECR"
  default     = "latest"
}

variable "download_image_tag" {
  type        = string
  description = "Container image tag for download-service in ECR"
  default     = "latest"
}

variable "processor_image_tag" {
  type        = string
  description = "Container image tag for processor-service in ECR"
  default     = "latest"
}

############################
# GitHub Actions OIDC (passwordless) - Infra repo
############################

variable "github_org" {
  type        = string
  description = "GitHub organization/owner for OIDC trust (e.g., the-code-crafters-hackathon)"
  default     = "the-code-crafters-hackathon"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name for OIDC trust (e.g., infra)"
  default     = "infra"
}

variable "github_branch" {
  type        = string
  description = "Branch allowed to assume the OIDC role (e.g., main)"
  default     = "main"
}

variable "github_oidc_thumbprint" {
  type        = string
  description = "OIDC provider thumbprint for token.actions.githubusercontent.com. Update if GitHub changes certificates."
  # Thumbprint comum usado para GitHub Actions OIDC (pode mudar ao longo do tempo)
  default = "6938fd4d98bab03faadb97b34396831e3780aea1"
}

variable "github_actions_role_name" {
  type        = string
  description = "IAM role name assumed by GitHub Actions via OIDC"
  default     = "hackathon-github-actions-infra"
}

############################
# GitHub Actions OIDC (passwordless) - Application repos
# - Used by CI/CD pipelines in upload/download/processor repos
# - Separate roles for plan (PR/branches) and deploy (main)
############################

variable "github_app_repos" {
  type        = list(string)
  description = "GitHub repository names for the application CI/CD (e.g., [\"upload-service\", \"download-service\", \"worker-service\"])."
  default = [
    "upload-service",
    "download-service",
    "worker-service",
    "processor-service",
  ]
}

variable "github_app_deploy_branch" {
  type        = string
  description = "Branch allowed to assume the deploy role for application repos (e.g., main)."
  default     = "main"
}

variable "github_actions_apps_deploy_role_name" {
  type        = string
  description = "IAM role name assumed by GitHub Actions (apps) via OIDC for deploy/apply (restricted to main)."
  default     = "hackathon-github-actions-apps-deploy"
}
