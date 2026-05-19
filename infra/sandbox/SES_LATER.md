# AWS SES SMTP — enable after sandbox validation

DocuSeal sandbox v1 runs **without** AWS SES (account is in SES sandbox; only verified recipients receive mail).

## When ready

1. Request **SES production access** in AWS Console (eu-north-1), or verify all test recipient addresses.
2. Update secret `inc-sandbox/docuseal` — add or replace SMTP lines:

```text
SMTP_ADDRESS=email-smtp.eu-north-1.amazonaws.com
SMTP_PORT=587
SMTP_USERNAME=<your-ses-smtp-username>
SMTP_PASSWORD=<your-ses-smtp-password>
SMTP_FROM=noreply@sandbox.innovationcity.com
SMTP_DOMAIN=sandbox.innovationcity.com
```

3. Force new ECS deployment: `aws ecs update-service --cluster inc-sandbox-apps --service inc-sandbox-docuseal --force-new-deployment --region eu-north-1`
4. Send a test signing invitation and confirm delivery.

## Gmail (optional interim testing)

Add Gmail App Password lines to the same secret, or use DocuSeal **Settings → Email SMTP** in the UI.
