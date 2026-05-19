# DocuSeal — AWS sandbox (eu-north-1)

Deploys `inc-sandbox-docuseal` on the existing Innovation City sandbox stack.

## Prerequisites

- AWS CLI, Terraform >= 1.5
- Access to account `614073401540`, region `eu-north-1`
- Permission to write Terraform state bucket `inc-terraform-state-eu-north-1`

## Deploy

```bash
cd infra/sandbox/terraform
terraform init
terraform plan
terraform apply
```

`terraform apply` will:

1. Create S3, Secrets Manager, IAM, security groups, target group, ALB rule, ACM cert
2. Run a one-off ECS task to create `docuseal` database on `inc-sandbox-postgres`
3. Start the DocuSeal ECS service

## DNS (required)

After apply, configure **external** DNS for `innovationcity.com`:

1. **ACM validation** — CNAMEs from `terraform output acm_validation_records`
2. **App** — CNAME `sign-sandbox.innovationcity.com` → `terraform output -raw alb_dns_name`

## Validate

```bash
curl -sI https://sign-sandbox.innovationcity.com/up
```

Complete setup wizard, upload a test PDF, check S3 bucket `inc-sandbox-docuseal`.

## Email

See [SES_LATER.md](./SES_LATER.md). Optional Gmail via secret or UI.

## Discovery notes

See [DISCOVERY.md](./DISCOVERY.md).
