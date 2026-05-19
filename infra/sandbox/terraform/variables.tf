variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "environment" {
  type    = string
  default = "sandbox"
}

variable "vpc_id" {
  type    = string
  default = "vpc-0403a8468a8f2f938"
}

variable "subnet_ids" {
  type = list(string)
  default = [
    "subnet-0aaa27106cda1828d",
    "subnet-0f62371af5083c336",
    "subnet-029ad909ac1f329e2",
  ]
}

variable "ecs_cluster_name" {
  type    = string
  default = "inc-sandbox-apps"
}

variable "alb_name" {
  type    = string
  default = "inc-sandbox-apps-alb"
}

variable "alb_listener_rule_priority" {
  type    = number
  default = 68
}

variable "hostname" {
  type    = string
  default = "sign-sandbox.innovationcity.com"
}

variable "rds_endpoint" {
  type    = string
  default = "inc-sandbox-postgres.cbwmwy846qjb.eu-north-1.rds.amazonaws.com"
}

variable "rds_master_secret_arn" {
  type    = string
  default = "arn:aws:secretsmanager:eu-north-1:614073401540:secret:inc-sandbox/rds-proxy-credentials"
}

variable "rds_security_group_id" {
  type    = string
  default = "sg-0492145437b2e8b49"
}

variable "alb_security_group_id" {
  type    = string
  default = "sg-090a97c9aeed798ec"
}

variable "reference_execution_role_name" {
  type    = string
  default = "inc-sandbox-app-document-exec"
}

variable "docuseal_image" {
  type    = string
  default = "docuseal/docuseal:latest"
}

variable "desired_count" {
  type    = number
  default = 1
}
