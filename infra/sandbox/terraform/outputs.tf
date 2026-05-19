output "app_url" {
  value       = local.app_url
  description = "DocuSeal sandbox URL (after DNS is configured)"
}

output "alb_dns_name" {
  value       = data.aws_lb.sandbox.dns_name
  description = "CNAME target for sign-sandbox.innovationcity.com"
}

output "acm_validation_records" {
  value = {
    for dvo in aws_acm_certificate.docuseal.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
  description = "Add these CNAME records in your DNS provider for TLS"
}

output "ecs_service_name" {
  value = aws_ecs_service.docuseal.name
}

output "s3_bucket" {
  value = aws_s3_bucket.docuseal.id
}

output "secret_arn" {
  value       = aws_secretsmanager_secret.docuseal.arn
  description = "DocuSeal config secret (SMTP can be added later)"
}

output "log_group" {
  value = aws_cloudwatch_log_group.docuseal.name
}

output "docuseal_task_security_group_id" {
  value = aws_security_group.docuseal_task.id
}
