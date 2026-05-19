#!/usr/bin/env bash
# Run after terraform apply: creates docuseal DB/user via ECS task in VPC
set -euo pipefail
export PYTHONWARNINGS=ignore
export AWS_CA_BUNDLE="${AWS_CA_BUNDLE:-$(python -c "import certifi; print(certifi.where())")}"
REGION=eu-north-1
CLUSTER=inc-sandbox-apps
TASK_DEF=inc-sandbox-docuseal-db-init

SUBNETS="subnet-0aaa27106cda1828d,subnet-0f62371af5083c336"
SG=$(terraform -chdir="$(dirname "$0")" output -raw docuseal_task_security_group_id 2>/dev/null || aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=inc-sandbox-docuseal-task-sg" --query 'SecurityGroups[0].GroupId' --output text)

TASK_ARN=$(aws ecs run-task --region "$REGION" \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEF" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=ENABLED}" \
  --query 'tasks[0].taskArn' --output text)

echo "Waiting for db-init task: $TASK_ARN"
aws ecs wait tasks-stopped --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN"
EXIT=$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].containers[0].exitCode' --output text)
if [ "$EXIT" != "0" ]; then
  echo "db-init failed with exit code $EXIT"
  aws logs tail "/ecs/inc-sandbox/docuseal" --region "$REGION" --since 10m 2>/dev/null || true
  exit 1
fi
echo "Database docuseal ready."
