data "aws_caller_identity" "current" {}

data "aws_lb" "sandbox" {
  name = var.alb_name
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.sandbox.arn
  port              = 443
}

data "aws_secretsmanager_secret" "rds_master" {
  name = "inc-sandbox/rds-proxy-credentials"
}

data "aws_iam_policy" "ecs_execution" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "random_password" "docuseal_db" {
  length  = 32
  special = false
}

resource "aws_security_group" "docuseal_task" {
  name        = "${local.name_prefix}-task-sg"
  description = "DocuSeal Fargate task (sandbox)"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-task-sg" })
}

resource "aws_security_group_rule" "alb_to_docuseal" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.docuseal_task.id
  source_security_group_id = var.alb_security_group_id
  description              = "HTTPS from sandbox ALB"
}

resource "aws_security_group_rule" "rds_from_docuseal" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = var.rds_security_group_id
  source_security_group_id = aws_security_group.docuseal_task.id
  description              = "PostgreSQL from DocuSeal task"
}

resource "aws_s3_bucket" "docuseal" {
  bucket = "inc-sandbox-docuseal"
  tags   = merge(local.common_tags, { Name = "inc-sandbox-docuseal" })
}

resource "aws_s3_bucket_public_access_block" "docuseal" {
  bucket = aws_s3_bucket.docuseal.id

  block_public_acls       = true
  block_public_policy       = true
  ignore_public_acls        = true
  restrict_public_buckets   = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "docuseal" {
  bucket = aws_s3_bucket.docuseal.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_secretsmanager_secret" "docuseal" {
  name        = "inc-sandbox/docuseal"
  description = "DocuSeal sandbox configuration (KEY=value lines for AWS_SECRET_MANAGER_ID)"
  tags        = local.common_tags
}

resource "aws_secretsmanager_secret_version" "docuseal" {
  secret_id = aws_secretsmanager_secret.docuseal.id
  secret_string = join("\n", [
    "SECRET_KEY_BASE=${random_password.secret_key_base.result}",
    "DATABASE_URL=postgresql://docuseal:${random_password.docuseal_db.result}@${var.rds_endpoint}:5432/docuseal",
    "APP_URL=${local.app_url}",
    "FORCE_SSL=true",
    "S3_ATTACHMENTS_BUCKET=${aws_s3_bucket.docuseal.id}",
    "AWS_REGION=${var.aws_region}",
    "RUN_MIGRATIONS=true",
  ])
}

resource "random_password" "secret_key_base" {
  length  = 128
  special = false
}

resource "aws_iam_role" "docuseal_execution" {
  name = "${local.name_prefix}-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "docuseal_execution" {
  role       = aws_iam_role.docuseal_execution.name
  policy_arn = data.aws_iam_policy.ecs_execution.arn
}

resource "aws_iam_role_policy" "docuseal_execution_secrets" {
  name = "${local.name_prefix}-exec-secrets"
  role = aws_iam_role.docuseal_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.docuseal.arn,
        data.aws_secretsmanager_secret.rds_master.arn
      ]
    }]
  })
}

resource "aws_iam_role" "docuseal_task" {
  name = "${local.name_prefix}-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "docuseal_task" {
  name = "${local.name_prefix}-task-policy"
  role = aws_iam_role.docuseal_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.docuseal.arn,
          "${aws_s3_bucket.docuseal.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.docuseal.arn]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "docuseal" {
  name              = "/ecs/inc-sandbox/docuseal"
  retention_in_days = 30
  tags              = local.common_tags
}

resource "aws_ecs_task_definition" "docuseal" {
  family                   = local.name_prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.docuseal_execution.arn
  task_role_arn            = aws_iam_role.docuseal_task.arn

  container_definitions = jsonencode([{
    name      = "docuseal"
    image     = var.docuseal_image
    essential = true
    portMappings = [{
      containerPort = 3000
      protocol      = "tcp"
    }]
    environment = [
      { name = "RAILS_ENV", value = "production" },
      { name = "AWS_REGION", value = var.aws_region },
      { name = "AWS_SECRET_MANAGER_ID", value = aws_secretsmanager_secret.docuseal.name },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.docuseal.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "docuseal"
      }
    }
  }])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  ephemeral_storage {
    size_in_gib = 21
  }

  tags = local.common_tags
}

resource "aws_lb_target_group" "docuseal" {
  name        = local.name_prefix
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/up"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.common_tags
}

resource "aws_lb_listener_rule" "docuseal" {
  listener_arn = data.aws_lb_listener.https.arn
  priority     = var.alb_listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.docuseal.arn
  }

  condition {
    host_header {
      values = [var.hostname]
    }
  }
}

resource "aws_ecs_service" "docuseal" {
  name            = local.name_prefix
  cluster         = var.ecs_cluster_name
  task_definition = aws_ecs_task_definition.docuseal.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.docuseal_task.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.docuseal.arn
    container_name   = "docuseal"
    container_port   = 3000
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent           = 200

  depends_on = [
    aws_lb_listener_rule.docuseal,
    null_resource.db_init,
  ]

  tags = local.common_tags
}

# One-shot task to create DB/user inside VPC (RDS not reachable from developer machines)
resource "aws_ecs_task_definition" "db_init" {
  family                   = "${local.name_prefix}-db-init"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn = aws_iam_role.docuseal_execution.arn

  container_definitions = jsonencode([{
    name      = "psql"
    image     = "postgres:16-alpine"
    essential = true
    command = [
      "sh", "-c",
      "set -e; export PGPASSWORD=\"$MASTER_PASSWORD\"; psql -h ${var.rds_endpoint} -U dbadmin -d inc_sandbox_db -p 5432 -tc \"SELECT 1 FROM pg_roles WHERE rolname='docuseal'\" | grep -q 1 || psql -h ${var.rds_endpoint} -U dbadmin -d inc_sandbox_db -p 5432 -c \"CREATE ROLE docuseal LOGIN PASSWORD '$DOCUSEAL_PASSWORD'\"; psql -h ${var.rds_endpoint} -U dbadmin -d inc_sandbox_db -p 5432 -tc \"SELECT 1 FROM pg_database WHERE datname='docuseal'\" | grep -q 1 || psql -h ${var.rds_endpoint} -U dbadmin -d inc_sandbox_db -p 5432 -c \"CREATE DATABASE docuseal OWNER docuseal\""
    ]
    environment = [
      { name = "DOCUSEAL_PASSWORD", value = random_password.docuseal_db.result },
    ]
    secrets = [{
      name      = "MASTER_PASSWORD"
      valueFrom = "${data.aws_secretsmanager_secret.rds_master.arn}:password::"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.docuseal.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "db-init"
      }
    }
  }])

  tags = local.common_tags
}

resource "null_resource" "db_init" {
  triggers = {
    task_def = aws_ecs_task_definition.db_init.revision
    password = random_password.docuseal_db.result
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/run-db-init.sh"
    interpreter = ["bash", "-c"]
  }

  depends_on = [
    aws_ecs_task_definition.db_init,
    aws_security_group_rule.rds_from_docuseal,
    aws_cloudwatch_log_group.docuseal,
  ]
}

resource "aws_acm_certificate" "docuseal" {
  domain_name       = var.hostname
  validation_method = "DNS"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-cert" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_certificate" "docuseal" {
  listener_arn    = data.aws_lb_listener.https.arn
  certificate_arn = aws_acm_certificate.docuseal.arn

  depends_on = [aws_acm_certificate.docuseal]
}

resource "aws_cloudwatch_metric_alarm" "docuseal_unhealthy" {
  alarm_name          = "${local.name_prefix}-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "DocuSeal sandbox target group has unhealthy hosts"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroup  = aws_lb_target_group.docuseal.arn_suffix
    LoadBalancer = data.aws_lb.sandbox.arn_suffix
  }

  tags = local.common_tags
}
