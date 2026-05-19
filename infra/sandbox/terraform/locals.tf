locals {
  name_prefix = "inc-sandbox-docuseal"
  app_url     = "https://${var.hostname}"

  common_tags = {
    Project     = "docuseal"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
