############################################
# Hackathon (SOAT) - Network baseline (No NAT)
# Region: us-east-1
# Public subnets: ALB + ECS tasks (public IP for egress)
# Private subnets: RDS
# NOTE: This file intentionally sets up only VPC + routing + SGs.
#       ECS/ALB/RDS/S3/SQS/ECR will be added in subsequent commits.
############################################

terraform {
  # Backend is configured in versions.tf (S3 + DynamoDB lock)
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  # Hard requirement from the group decision
  project_prefix = var.prefix

  # Keep CIDR isolated from Good Burger (choose a distinct range)
  vpc_cidr = "10.50.0.0/16"

  # Two AZs for ALB high-availability
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Project = local.project_prefix
    Env     = "dev"
    Managed = "terraform"
  }
}

############################
# VPC + Internet Gateway
############################

resource "aws_vpc" "this" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-igw"
  })
}

############################
# Subnets
# - Public: ALB + ECS tasks (assign_public_ip=true)
# - Private: RDS only
############################

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(aws_vpc.this.cidr_block, 8, count.index) # /24 blocks
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  # Private range starts at 10.50.10.0/24 (offset 10)
  cidr_block = cidrsubnet(aws_vpc.this.cidr_block, 8, 10 + count.index)

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

############################
# Route Tables
# - Public: 0.0.0.0/0 -> IGW
# - Private: no internet route (NO NAT)
############################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-rtb-public"
  })
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  # Intentionally no default route to the Internet.
  tags = merge(local.tags, {
    Name = "${local.project_prefix}-rtb-private"
  })
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

############################
# Security Groups
# - ALB: inbound 80 from Internet
# - API tasks: inbound 8000 ONLY from ALB
# - Worker: no inbound
# - RDS: inbound 5432 ONLY from API + Worker
############################

resource "aws_security_group" "alb" {
  name        = "${local.project_prefix}-sg-alb"
  description = "ALB ingress (HTTP 80)"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-sg-alb"
  })
}

resource "aws_security_group" "api" {
  name        = "${local.project_prefix}-sg-api"
  description = "Upload/Download ECS tasks - only ALB can reach port 8000"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "FastAPI 8000 from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All egress (tasks have public IP for egress; no NAT)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-sg-api"
  })
}

resource "aws_security_group" "worker" {
  name        = "${local.project_prefix}-sg-worker"
  description = "Processor ECS task - no inbound"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "All egress (SQS/S3/ECR/CloudWatch via public IP; no NAT)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-sg-worker"
  })
}

resource "aws_security_group" "rds" {
  name        = "${local.project_prefix}-sg-rds"
  description = "RDS Postgres - only ECS tasks can connect"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Postgres 5432 from API tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
  }

  ingress {
    description     = "Postgres 5432 from Worker tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.worker.id]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-sg-rds"
  })
}

############################
# RDS Postgres (Hackathon)
# - Dedicated instance (do NOT reuse Good Burger)
# - Runs in private subnets
############################

resource "aws_db_subnet_group" "hackathon" {
  name       = "${local.project_prefix}-db-subnet-group"
  subnet_ids = [for s in aws_subnet.private : s.id]

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-db-subnet-group"
  })
}

resource "aws_db_instance" "hackathon" {
  identifier = "${local.project_prefix}-postgres"

  engine         = "postgres"
  engine_version = "16"

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage_gb
  storage_type      = "gp3"

  db_name  = var.db_name
  username = var.db_username
  password = local.db_password_effective
  lifecycle {
    ignore_changes = [
      # Password is sourced from Secrets Manager; avoid unintended rotations via Terraform
      password
    ]
  }

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.hackathon.name

  publicly_accessible = false
  multi_az            = false

  backup_retention_period = var.db_backup_retention_days

  deletion_protection = false
  skip_final_snapshot = true

  auto_minor_version_upgrade = true

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-postgres"
  })
}

resource "aws_secretsmanager_secret" "db" {
  name        = "${local.project_prefix}/rds/postgres"
  description = "Hackathon Postgres credentials"

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-db-secret"
  })
}

# Read the current DB credentials from Secrets Manager to avoid requiring db_password
# in CI/CD runs (GitHub Actions runners are ephemeral and cannot answer prompts).
data "aws_secretsmanager_secret_version" "db_current" {
  secret_id = aws_secretsmanager_secret.db.id
}

locals {
  db_secret_current = try(jsondecode(data.aws_secretsmanager_secret_version.db_current.secret_string), {})

  # If var.db_password is provided (bootstrap/rotation), use it; otherwise use the current secret value.
  db_password_effective = coalesce(var.db_password, try(local.db_secret_current.password, null))
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = local.db_password_effective
    dbname   = var.db_name
    host     = aws_db_instance.hackathon.address
    port     = aws_db_instance.hackathon.port
  })

  lifecycle {
    ignore_changes = [
      secret_string
    ]
  }

  depends_on = [aws_db_instance.hackathon]
}
############################
# SQS (Hackathon) - Jobs Queue + DLQ
############################

resource "aws_sqs_queue" "jobs_dlq" {
  name = "${local.project_prefix}-jobs-dlq"

  # DLQ geralmente não precisa de long polling; mas não atrapalha
  receive_wait_time_seconds = 0

  # Retenção maior ajuda a investigar falhas
  message_retention_seconds = 1209600 # 14 dias

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-jobs-dlq"
  })
}

resource "aws_sqs_queue" "jobs" {
  name = "${local.project_prefix}-jobs"

  # Long polling reduz custo e melhora eficiência do worker
  receive_wait_time_seconds = 20

  # Ajuste conforme tempo máximo esperado de processamento por job
  visibility_timeout_seconds = 300

  # Retenção padrão (ok para hackathon)
  message_retention_seconds = 345600 # 4 dias

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-jobs"
  })
}

############################
# S3 (Hackathon) - Media bucket
# - Stores input and output artifacts
############################

resource "aws_s3_bucket" "media" {
  bucket = "${local.project_prefix}-media-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-media"
  })
}

resource "aws_s3_bucket_versioning" "media" {
  bucket = aws_s3_bucket.media.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

############################
# ECR (Hackathon) - Repositories
############################

resource "aws_ecr_repository" "upload" {
  name                 = "upload-service"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.tags, {
    Name = "upload-service"
  })
}

resource "aws_ecr_lifecycle_policy" "upload" {
  repository = aws_ecr_repository.upload.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 20 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "release", "sha", "main"]
          countType     = "imageCountMoreThan"
          countNumber   = 20
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_repository" "download" {
  name                 = "download-service"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.tags, {
    Name = "download-service"
  })
}

resource "aws_ecr_lifecycle_policy" "download" {
  repository = aws_ecr_repository.download.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 20 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "release", "sha", "main"]
          countType     = "imageCountMoreThan"
          countNumber   = 20
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_repository" "processor" {
  name                 = "processor-service"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.tags, {
    Name = "processor-service"
  })
}

resource "aws_ecr_lifecycle_policy" "processor" {
  repository = aws_ecr_repository.processor.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 20 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "release", "sha", "main"]
          countType     = "imageCountMoreThan"
          countNumber   = 20
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

############################
# Cognito (Hackathon) - User authentication (User Pool)
# Goal: user/password auth and JWT validation in the APIs (no API Gateway).
# Notes (hackathon):
# - MFA disabled
# - Email/phone verification not required (reduces complexity/cost)
############################

resource "aws_cognito_user_pool" "this" {
  name = "${local.project_prefix}-user-pool"

  # Use email as the primary username identifier
  username_attributes = ["email"]

  # Keep it simple for hackathon: no mandatory verification flows
  auto_verified_attributes = []

  mfa_configuration = "OFF"

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # Allow only administrators to create users if you prefer controlled access.
  # You can switch to allow self sign-up later if needed.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-user-pool"
  })
}

resource "aws_cognito_user_pool_client" "this" {
  name         = "${local.project_prefix}-app-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = false

  # Enable USER_PASSWORD_AUTH (simple username/password auth)
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_ADMIN_USER_PASSWORD_AUTH"
  ]

  # Keep tokens simple for APIs
  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  supported_identity_providers = ["COGNITO"]
}

############################
# CloudWatch Logs (Hackathon)
# - One log group per service
# - Short retention for hackathon cost control
############################

resource "aws_cloudwatch_log_group" "upload" {
  name              = "/ecs/${local.project_prefix}/upload"
  retention_in_days = 7

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-logs-upload"
  })
}

resource "aws_cloudwatch_log_group" "download" {
  name              = "/ecs/${local.project_prefix}/download"
  retention_in_days = 7

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-logs-download"
  })
}

resource "aws_cloudwatch_log_group" "processor" {
  name              = "/ecs/${local.project_prefix}/processor"
  retention_in_days = 7

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-logs-processor"
  })
}

############################
# ECS Cluster (Hackathon)
# - Base compute layer for Fargate services (Upload, Download, Processor)
############################

resource "aws_ecs_cluster" "this" {
  name = "${local.project_prefix}-cluster"

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-cluster"
  })
}

############################
# GitHub Actions OIDC (passwordless)
# - Allows GitHub Actions to assume an IAM role without static AWS keys
# - Scope restricted to a single repo and branch
############################

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  thumbprint_list = [
    var.github_oidc_thumbprint
  ]

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-github-oidc"
  })
}

resource "aws_iam_role" "github_actions_infra" {
  name = var.github_actions_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          },
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = merge(local.tags, {
    Name = var.github_actions_role_name
  })
}

# Hackathon shortcut: Admin access for the infra pipeline.
# You can replace this with a least-privilege policy later.
resource "aws_iam_role_policy_attachment" "github_actions_infra_admin" {
  role       = aws_iam_role.github_actions_infra.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

############################
# IAM Roles (ECS)
# - Execution Role: used by ECS agent to pull images, write logs, and fetch secrets
# - Task Role: assumed by the application code to access AWS services (SQS/S3)
############################

# 1) Execution role (ECS agent)
resource "aws_iam_role" "ecs_task_execution" {
  name = "${local.project_prefix}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-ecs-execution-role"
  })
}

# Attach AWS managed policy for ECR pull + CloudWatch logs
resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow execution role to read the DB secret (so ECS can inject secrets into containers)
resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  name = "${local.project_prefix}-ecs-exec-secrets"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ],
        Resource = aws_secretsmanager_secret.db.arn
      }
    ]
  })
}

# 2) Task role (application code)
resource "aws_iam_role" "ecs_task" {
  name = "${local.project_prefix}-ecs-application-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-ecs-application-role"
  })
}

# Minimal runtime permissions for the services
resource "aws_iam_role_policy" "ecs_task_access" {
  name = "${local.project_prefix}-ecs-task-access"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "SQSAccess",
        Effect = "Allow",
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ],
        Resource = [
          aws_sqs_queue.jobs.arn,
          aws_sqs_queue.jobs_dlq.arn
        ]
      },
      {
        Sid    = "S3Access",
        Effect = "Allow",
        Action = [
          "s3:ListBucket"
        ],
        Resource = aws_s3_bucket.media.arn
      },
      {
        Sid    = "S3ObjectAccess",
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ],
        Resource = "${aws_s3_bucket.media.arn}/*"
      }
    ]
  })
}

############################
# ECS Task Definition (Upload) - Placeholder image
# - Define COMO o container roda (não onde/quantos)
# - Usa o log group /ecs/hackathon/upload
# - Expõe porta 8000 para o ALB no passo seguinte
############################

resource "aws_ecs_task_definition" "upload" {
  family                   = "${local.project_prefix}-upload"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "upload"
      image     = "hashicorp/http-echo:0.2.3"
      essential = true

      # placeholder que responde em qualquer path, inclusive /health
      command = ["-listen=:8000", "-text=upload ok"]

      portMappings = [
        {
          containerPort = 8000
          protocol      = "tcp"
        }
      ]

      # Variáveis já no formato que o serviço real vai usar depois
      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "S3_BUCKET", value = aws_s3_bucket.media.bucket },
        { name = "S3_INPUT_PREFIX", value = "input/" },
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.jobs.url },
        { name = "COGNITO_USER_POOL_ID", value = aws_cognito_user_pool.this.id },
        { name = "COGNITO_CLIENT_ID", value = aws_cognito_user_pool_client.this.id },
        { name = "COGNITO_ISSUER", value = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}" }
      ]

      # Secret do DB injetado pelo ECS (execution role precisa ter GetSecretValue)
      secrets = [
        {
          name      = "DB_SECRET"
          valueFrom = aws_secretsmanager_secret.db.arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.upload.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-taskdef-upload"
  })
}

############################
# ECS Task Definition (Download) - Placeholder image
# - Exposes port 8000 for ALB target groups later
############################

resource "aws_ecs_task_definition" "download" {
  family                   = "${local.project_prefix}-download"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "download"
      image     = "hashicorp/http-echo:0.2.3"
      essential = true

      command = ["-listen=:8000", "-text=download ok"]

      portMappings = [
        {
          containerPort = 8000
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "S3_BUCKET", value = aws_s3_bucket.media.bucket },
        { name = "S3_OUTPUT_PREFIX", value = "output/" },
        { name = "COGNITO_USER_POOL_ID", value = aws_cognito_user_pool.this.id },
        { name = "COGNITO_CLIENT_ID", value = aws_cognito_user_pool_client.this.id },
        { name = "COGNITO_ISSUER", value = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}" }
      ]

      secrets = [
        {
          name      = "DB_SECRET"
          valueFrom = aws_secretsmanager_secret.db.arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.download.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-taskdef-download"
  })
}

############################
# ECS Task Definition (Processor) - Placeholder worker
# - No inbound; consumes SQS in the real implementation
# - Placeholder just logs periodically
############################

resource "aws_ecs_task_definition" "processor" {
  family                   = "${local.project_prefix}-processor"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "processor"
      image     = "busybox:stable"
      essential = true

      command = ["sh", "-c", "while true; do echo processor alive; sleep 30; done"]

      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "S3_BUCKET", value = aws_s3_bucket.media.bucket },
        { name = "S3_INPUT_PREFIX", value = "input/" },
        { name = "S3_OUTPUT_PREFIX", value = "output/" },
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.jobs.url }
      ]

      secrets = [
        {
          name      = "DB_SECRET"
          valueFrom = aws_secretsmanager_secret.db.arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.processor.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-taskdef-processor"
  })
}

############################
# Step 5 - Runtime: ALB + Target Groups + ECS Services
# - Upload/Download behind ALB (HTTP :80)
# - Health check: /health
# - No NAT: tasks run in public subnets with public IP for egress
# - Cost control: processor desired_count defaults to 0
############################

# ALB
resource "aws_lb" "this" {
  count              = var.runtime_enabled ? 1 : 0
  name               = "${local.project_prefix}-alb"
  load_balancer_type = "application"
  internal           = false

  security_groups = [aws_security_group.alb.id]
  subnets         = [for s in aws_subnet.public : s.id]

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-alb"
  })
}

# Target Group - Upload
resource "aws_lb_target_group" "upload" {
  count       = var.runtime_enabled ? 1 : 0
  name        = "${local.project_prefix}-tg-up"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 15
    matcher             = "200-399"
  }

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-tg-up"
  })
}

# Target Group - Download
resource "aws_lb_target_group" "download" {
  count       = var.runtime_enabled ? 1 : 0
  name        = "${local.project_prefix}-tg-dl"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 15
    matcher             = "200-399"
  }

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-tg-dl"
  })
}

# Listener 80
resource "aws_lb_listener" "http" {
  count             = var.runtime_enabled ? 1 : 0
  load_balancer_arn = aws_lb.this[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "OK"
      status_code  = "200"
    }
  }
}

# Path rules
resource "aws_lb_listener_rule" "upload" {
  count        = var.runtime_enabled ? 1 : 0
  listener_arn = aws_lb_listener.http[0].arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.upload[0].arn
  }

  condition {
    path_pattern {
      values = ["/upload*", "/upload/*"]
    }
  }
}

resource "aws_lb_listener_rule" "download" {
  count        = var.runtime_enabled ? 1 : 0
  listener_arn = aws_lb_listener.http[0].arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.download[0].arn
  }

  condition {
    path_pattern {
      values = ["/download*", "/download/*"]
    }
  }
}

# ECS Services
resource "aws_ecs_service" "upload" {
  count           = var.runtime_enabled ? 1 : 0
  name            = "${local.project_prefix}-upload"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.upload.arn
  desired_count   = 1

  launch_type = "FARGATE"

  network_configuration {
    subnets          = [for s in aws_subnet.public : s.id]
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.upload[0].arn
    container_name   = "upload"
    container_port   = 8000
  }

  depends_on = [
    aws_lb_listener.http[0],
    aws_lb_listener_rule.upload[0]
  ]

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-svc-upload"
  })
}

resource "aws_ecs_service" "download" {
  count           = var.runtime_enabled ? 1 : 0
  name            = "${local.project_prefix}-download"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.download.arn
  desired_count   = 1

  launch_type = "FARGATE"

  network_configuration {
    subnets          = [for s in aws_subnet.public : s.id]
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.download[0].arn
    container_name   = "download"
    container_port   = 8000
  }

  depends_on = [
    aws_lb_listener.http[0],
    aws_lb_listener_rule.download[0]
  ]

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-svc-download"
  })
}

resource "aws_ecs_service" "processor" {
  name            = "${local.project_prefix}-processor"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.processor.arn

  # Cost control: keep it off by default; set to 1 when testing async flow
  desired_count = 0

  launch_type = "FARGATE"

  network_configuration {
    subnets          = [for s in aws_subnet.public : s.id]
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = true
  }

  tags = merge(local.tags, {
    Name = "${local.project_prefix}-svc-processor"
  })
}

############################
# Outputs are defined in outputs.tf
############################