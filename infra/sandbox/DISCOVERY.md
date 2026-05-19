# DocuSeal sandbox — Phase 0 discovery (eu-north-1)

## Do not touch (production)

- ECS: `inc-prod-apps`, all `inc-prod-*` services
- RDS: `inc-prod-postgres`, `inc-prod-proxy`
- ALB: `inc-prod-apps-alb`
- Secrets: `inc-prod/*`

## Reuse (sandbox)

| Resource | ID / name |
|----------|-----------|
| Region | `eu-north-1` |
| VPC | `vpc-0403a8468a8f2f938` |
| Subnets | `subnet-0aaa27106cda1828d`, `subnet-0f62371af5083c336`, `subnet-029ad909ac1f329e2` |
| ECS cluster | `inc-sandbox-apps` |
| ALB | `inc-sandbox-apps-alb` |
| RDS | `inc-sandbox-postgres.cbwmwy846qjb.eu-north-1.rds.amazonaws.com` |
| RDS admin secret | `inc-sandbox/rds-proxy-credentials` |
| ECS SG (reference) | `sg-0242f3da600b36282` |
| ACM (default listener) | `app-sandbox.innovationcity.com` |
| ALB HTTPS listener | `.../bac50b5f7fb88467` |

## Reference ECS service: `inc-sandbox-app-document`

- Execution role: `inc-sandbox-app-document-exec`
- Task role: `inc-sandbox-app-document-task`
- Fargate, public IP, port 3040, health `/health`
- Log group: `/ecs/inc-sandbox/app-document`

## ALB listener rule priorities (443)

| Priority | Route |
|----------|--------|
| 50 | `/rag/*` |
| 55 | `bp-api-sandbox.innovationcity.com` |
| 60–67 | `/business-plan/*`, `/aws/v1/*` |
| **68** | **`sign-sandbox.innovationcity.com` → DocuSeal (new)** |
| 100 | `/tiktok-studio/*` |
| default | catch-all |

## Hostname / TLS

- Plan hostname: `sign-sandbox.innovationcity.com`
- Default ACM cert only covers `app-sandbox.innovationcity.com` — add **additional ACM cert** on listener (SNI) for `sign-sandbox.innovationcity.com`
- Public DNS for `innovationcity.com` is **not** in this AWS account; add ACM validation + ALB CNAME in external DNS

## Email (sandbox v1)

- AWS SES SMTP: deferred (sandbox mode)
- Optional Gmail SMTP via `inc-sandbox/docuseal` secret or DocuSeal UI
