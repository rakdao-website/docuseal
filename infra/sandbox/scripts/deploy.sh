#!/usr/bin/env bash
# Deploy DocuSeal sandbox to eu-north-1 (additive on inc-sandbox stack)
set -euo pipefail
export PYTHONWARNINGS=ignore
export MSYS_NO_PATHCONV=1
export AWS_CA_BUNDLE="${AWS_CA_BUNDLE:-$(python -c "import certifi; print(certifi.where())")}"

REGION=eu-north-1
ACCOUNT=614073401540
PREFIX=inc-sandbox-docuseal
CLUSTER=inc-sandbox-apps
VPC=vpc-0403a8468a8f2f938
SUBNETS="subnet-0aaa27106cda1828d,subnet-0f62371af5083c336,subnet-029ad909ac1f329e2"
ALB_SG=sg-090a97c9aeed798ec
RDS_SG=sg-0492145437b2e8b49
RDS_HOST=inc-sandbox-postgres.cbwmwy846qjb.eu-north-1.rds.amazonaws.com
HOSTNAME=sign-sandbox.innovationcity.com
LISTENER_ARN=arn:aws:elasticloadbalancing:eu-north-1:614073401540:listener/app/inc-sandbox-apps-alb/b0b9a390b489d97a/bac50b5f7fb88467
ALB_ARN=arn:aws:elasticloadbalancing:eu-north-1:614073401540:loadbalancer/app/inc-sandbox-apps-alb/b0b9a390b489d97a
RULE_PRIORITY=68
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$SCRIPT_DIR/../.deploy-state"
mkdir -p "$STATE_DIR"

log() { echo "[deploy] $*"; }

# --- passwords ---
if [ ! -f "$STATE_DIR/.passwords" ]; then
  DOCUSEAL_DB_PASSWORD=$(openssl rand -hex 24)
  SECRET_KEY_BASE=$(openssl rand -hex 64)
  printf 'DOCUSEAL_DB_PASSWORD=%s\nSECRET_KEY_BASE=%s\n' "$DOCUSEAL_DB_PASSWORD" "$SECRET_KEY_BASE" > "$STATE_DIR/.passwords"
  chmod 600 "$STATE_DIR/.passwords"
fi
# shellcheck source=/dev/null
source "$STATE_DIR/.passwords"

# --- security group ---
if [ ! -f "$STATE_DIR/task_sg_id" ]; then
  TASK_SG=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "${PREFIX}-task-sg" \
    --description "DocuSeal sandbox Fargate" \
    --vpc-id "$VPC" \
    --query GroupId --output text 2>/dev/null || \
    aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=group-name,Values=${PREFIX}-task-sg" \
      --query 'SecurityGroups[0].GroupId' --output text)
  echo "$TASK_SG" > "$STATE_DIR/task_sg_id"
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$TASK_SG" \
    --protocol tcp --port 3000 --source-group "$ALB_SG" 2>/dev/null || true
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$RDS_SG" \
    --protocol tcp --port 5432 --source-group "$TASK_SG" 2>/dev/null || true
  log "Task SG: $TASK_SG"
else
  TASK_SG=$(cat "$STATE_DIR/task_sg_id")
fi

# --- S3 ---
if ! aws s3api head-bucket --bucket inc-sandbox-docuseal 2>/dev/null; then
  aws s3api create-bucket --bucket inc-sandbox-docuseal --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
  aws s3api put-public-access-block --bucket inc-sandbox-docuseal --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  log "S3 bucket created"
fi

# --- IAM roles ---
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${PREFIX}-exec"
TASK_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${PREFIX}-task"

create_role() {
  local name=$1 trust=$2
  aws iam get-role --role-name "$name" 2>/dev/null || \
    aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" >/dev/null
}

create_role "${PREFIX}-exec" '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
create_role "${PREFIX}-task" '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam attach-role-policy --role-name "${PREFIX}-exec" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null || true

SECRET_ARN=$(aws secretsmanager describe-secret --region "$REGION" --secret-id inc-sandbox/docuseal --query ARN --output text 2>/dev/null || echo "")
RDS_SECRET_ARN=$(aws secretsmanager describe-secret --region "$REGION" --secret-id inc-sandbox/rds-proxy-credentials --query ARN --output text)

aws iam put-role-policy --role-name "${PREFIX}-exec" --policy-name "${PREFIX}-exec-inline" --policy-document "$(cat <<POL
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue"],
    "Resource": ["${RDS_SECRET_ARN}", "${SECRET_ARN:-arn:aws:secretsmanager:${REGION}:${ACCOUNT}:secret:inc-sandbox/docuseal-*}"]
  }]
}
POL
)" 2>/dev/null || true

aws iam put-role-policy --role-name "${PREFIX}-task" --policy-name "${PREFIX}-task-inline" --policy-document "$(cat <<POL
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject","s3:ListBucket"],
      "Resource": ["arn:aws:s3:::inc-sandbox-docuseal", "arn:aws:s3:::inc-sandbox-docuseal/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": ["${SECRET_ARN:-arn:aws:secretsmanager:${REGION}:${ACCOUNT}:secret:inc-sandbox/docuseal-*}"]
    }
  ]
}
POL
)"

# --- secret ---
SECRET_BODY=$(cat <<EOF
SECRET_KEY_BASE=${SECRET_KEY_BASE}
DATABASE_URL=postgresql://docuseal:${DOCUSEAL_DB_PASSWORD}@${RDS_HOST}:5432/docuseal
APP_URL=https://${HOSTNAME}
FORCE_SSL=true
S3_ATTACHMENTS_BUCKET=inc-sandbox-docuseal
AWS_REGION=${REGION}
RUN_MIGRATIONS=true
EOF
)
if [ -z "$SECRET_ARN" ]; then
  SECRET_ARN=$(aws secretsmanager create-secret --region "$REGION" \
    --name inc-sandbox/docuseal \
    --description "DocuSeal sandbox config" \
    --secret-string "$SECRET_BODY" \
    --query ARN --output text)
else
  aws secretsmanager put-secret-value --region "$REGION" \
    --secret-id inc-sandbox/docuseal --secret-string "$SECRET_BODY" >/dev/null
fi
log "Secret: inc-sandbox/docuseal"

# --- log group ---
aws logs create-log-group --region "$REGION" --log-group-name /ecs/inc-sandbox/docuseal 2>/dev/null || true

# --- db init via ECS ---
DB_INIT_FAMILY=${PREFIX}-db-init
MASTER_ARN="${RDS_SECRET_ARN}"
cat > "$STATE_DIR/db-init-task.json" <<JSON
{
  "family": "${DB_INIT_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "containerDefinitions": [{
    "name": "psql",
    "image": "postgres:16-alpine",
    "essential": true,
    "command": ["sh","-c","set -e; export PGPASSWORD=\$MASTER_PASSWORD; psql -h ${RDS_HOST} -U dbadmin -d inc_sandbox_db -p 5432 -tc \"SELECT 1 FROM pg_roles WHERE rolname='docuseal'\" | grep -q 1 || psql -h ${RDS_HOST} -U dbadmin -d inc_sandbox_db -p 5432 -c \"CREATE ROLE docuseal LOGIN PASSWORD '${DOCUSEAL_DB_PASSWORD}'\"; psql -h ${RDS_HOST} -U dbadmin -d inc_sandbox_db -p 5432 -tc \"SELECT 1 FROM pg_database WHERE datname='docuseal'\" | grep -q 1 || psql -h ${RDS_HOST} -U dbadmin -d inc_sandbox_db -p 5432 -c \"CREATE DATABASE docuseal OWNER docuseal\""],
    "secrets": [{"name":"MASTER_PASSWORD","valueFrom":"${MASTER_ARN}:password::"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/inc-sandbox/docuseal",
        "awslogs-region": "${REGION}",
        "awslogs-stream-prefix": "db-init"
      }
    }
  }]
}
JSON
aws ecs register-task-definition --region "$REGION" --cli-input-json "$(cat "$STATE_DIR/db-init-task.json")" >/dev/null

if [ ! -f "$STATE_DIR/db_init_done" ]; then
  TASK_ARN=$(aws ecs run-task --region "$REGION" --cluster "$CLUSTER" \
    --task-definition "$DB_INIT_FAMILY" --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${TASK_SG}],assignPublicIp=ENABLED}" \
    --query 'tasks[0].taskArn' --output text)
  log "DB init task: $TASK_ARN"
  aws ecs wait tasks-stopped --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN"
  EXIT=$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN" \
    --query 'tasks[0].containers[0].exitCode' --output text)
  [ "$EXIT" = "0" ] || { log "DB init failed exit=$EXIT"; exit 1; }
  touch "$STATE_DIR/db_init_done"
  log "Database ready"
fi

# --- ACM cert ---
if [ ! -f "$STATE_DIR/cert_arn" ]; then
  CERT_ARN=$(aws acm request-certificate --region "$REGION" \
    --domain-name "$HOSTNAME" --validation-method DNS \
    --query CertificateArn --output text)
  echo "$CERT_ARN" > "$STATE_DIR/cert_arn"
  log "ACM cert requested: $CERT_ARN"
  log "Add DNS validation records from: aws acm describe-certificate --certificate-arn $CERT_ARN --region $REGION"
  sleep 5
else
  CERT_ARN=$(cat "$STATE_DIR/cert_arn")
fi
aws elbv2 add-listener-certificates --region "$REGION" \
  --listener-arn "$LISTENER_ARN" --certificates CertificateArn="$CERT_ARN" 2>/dev/null || true

# --- target group ---
if [ ! -f "$STATE_DIR/tg_arn" ]; then
  TG_ARN=$(aws elbv2 create-target-group --region "$REGION" \
    --name "$PREFIX" --port 3000 --protocol HTTP --vpc-id "$VPC" --target-type ip \
    --health-check-path /up --health-check-interval-seconds 30 \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || \
    aws elbv2 describe-target-groups --region "$REGION" --names "$PREFIX" \
      --query 'TargetGroups[0].TargetGroupArn' --output text)
  echo "$TG_ARN" > "$STATE_DIR/tg_arn"
else
  TG_ARN=$(cat "$STATE_DIR/tg_arn")
fi

aws elbv2 create-rule --region "$REGION" --listener-arn "$LISTENER_ARN" --priority "$RULE_PRIORITY" \
  --conditions "Field=host-header,Values=${HOSTNAME}" \
  --actions "Type=forward,TargetGroupArn=${TG_ARN}" 2>/dev/null || log "ALB rule may already exist"

# --- docuseal task + service ---
cat > "$STATE_DIR/docuseal-task.json" <<JSON
{
  "family": "${PREFIX}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "containerDefinitions": [{
    "name": "docuseal",
    "image": "docuseal/docuseal:latest",
    "essential": true,
    "portMappings": [{"containerPort": 3000, "protocol": "tcp"}],
    "environment": [
      {"name": "RAILS_ENV", "value": "production"},
      {"name": "AWS_REGION", "value": "${REGION}"},
      {"name": "AWS_SECRET_MANAGER_ID", "value": "inc-sandbox/docuseal"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/inc-sandbox/docuseal",
        "awslogs-region": "${REGION}",
        "awslogs-stream-prefix": "docuseal"
      }
    }
  }],
  "ephemeralStorage": {"sizeInGiB": 21}
}
JSON
aws ecs register-task-definition --region "$REGION" --cli-input-json "$(cat "$STATE_DIR/docuseal-task.json")" >/dev/null

if ! aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$PREFIX" \
  --query 'services[?status==`ACTIVE`].serviceName' --output text 2>/dev/null | grep -q "$PREFIX"; then
  aws ecs create-service --region "$REGION" --cluster "$CLUSTER" --service-name "$PREFIX" \
    --task-definition "$PREFIX" --desired-count 1 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${TASK_SG}],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=${TG_ARN},containerName=docuseal,containerPort=3000" \
    --deployment-configuration "minimumHealthyPercent=0,maximumPercent=200" \
    --health-check-grace-period-seconds 120 >/dev/null
  log "ECS service created"
else
  aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$PREFIX" \
    --task-definition "$PREFIX" --force-new-deployment >/dev/null
  log "ECS service updated"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)

log "Done."
echo ""
echo "1. Add ACM DNS validation (if cert pending):"
aws acm describe-certificate --region "$REGION" --certificate-arn "$CERT_ARN" \
  --query 'Certificate.DomainValidationOptions[*].ResourceRecord' --output table 2>/dev/null || true
echo ""
echo "2. CNAME ${HOSTNAME} -> ${ALB_DNS}"
echo "3. Open https://${HOSTNAME} after DNS propagates"
echo "4. Logs: aws logs tail /ecs/inc-sandbox/docuseal --follow --region ${REGION}"
