# DocuSeal sandbox deployment status

**Deployed:** 2026-05-19  
**Region:** eu-north-1  
**Service:** `inc-sandbox-docuseal` on cluster `inc-sandbox-apps`

## What was created (additive)

| Resource | Name / ID |
|----------|-----------|
| ECS service | `inc-sandbox-docuseal` |
| Target group | `inc-sandbox-docuseal` (port 3000, health `/up`) |
| ALB rule | Priority 68, host `sign-sandbox.innovationcity.com` |
| S3 bucket | `inc-sandbox-docuseal` |
| Secret | `inc-sandbox/docuseal` |
| IAM roles | `inc-sandbox-docuseal-exec`, `inc-sandbox-docuseal-task` |
| Security group | `inc-sandbox-docuseal-task-sg` |
| RDS database | `docuseal` on `inc-sandbox-postgres` |
| ACM certificate | `sign-sandbox.innovationcity.com` (pending DNS validation) |
| Log group | `/ecs/inc-sandbox/docuseal` |

## Verification (without public DNS)

Target is **healthy**. Health check via ALB:

```bash
export MSYS_NO_PATHCONV=1
curl -sk -H "Host: sign-sandbox.innovationcity.com" \
  https://inc-sandbox-apps-alb-1299133322.eu-north-1.elb.amazonaws.com/up
# Expect: 200
```

## Required DNS (external provider)

### 1. ACM validation CNAME

| Name | Type | Value |
|------|------|--------|
| `_c53c33e824650dbefe2705eecf30a1ea.sign-sandbox.innovationcity.com.` | CNAME | `_fea94a8b3d591b1c7cf42dc7a1f1900b.jkddzztszm.acm-validations.aws.` |

Refresh with:

```bash
aws acm describe-certificate --region eu-north-1 \
  --certificate-arn arn:aws:acm:eu-north-1:614073401540:certificate/5ea9edf8-3df6-49d4-9ba0-80875ed80825 \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord'
```

### 2. Application CNAME

| Name | Type | Value |
|------|------|--------|
| `sign-sandbox.innovationcity.com` | CNAME | `inc-sandbox-apps-alb-1299133322.eu-north-1.elb.amazonaws.com` |

Then open: **https://sign-sandbox.innovationcity.com**

## Email

Not configured (by design). See [SES_LATER.md](./SES_LATER.md) or add Gmail SMTP to secret `inc-sandbox/docuseal`.

## Re-deploy / update

```bash
cd infra/sandbox/scripts
export MSYS_NO_PATHCONV=1
bash deploy.sh
```

## Prod

Not deployed. No `inc-prod-*` resources were modified.
