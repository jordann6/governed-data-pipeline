terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# default_tags means every resource is tagged automatically. This is the first
# line of defense: you cannot create an untagged resource through this provider.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project     = "veeva-platform-lab"
      environment = var.environment
      owner       = var.owner
      cost_center = var.cost_center
      # The paved-road signature. Every resource born through this module carries
      # it; the AWS Config rule flags anything in the account that does NOT, which
      # is how an off-module (ClickOps) resource gets caught. See adoption.tf.
      managed_by = "pipeline-module"
    }
  }
}

# One call stamps out a fully governed pipeline: raw zone, curated zone,
# Glue transform job with least-privilege IAM, and an Athena database.
module "pipeline" {
  source                  = "./modules/pipeline"
  name                    = "demo"
  environment             = var.environment
  glue_max_dpus           = var.glue_max_dpus
  evidence_retention_days = var.evidence_retention_days
  cost_center             = var.cost_center
  monthly_budget          = var.monthly_budget
  finops_alert_email      = var.finops_alert_email
  enable_config_guardrail = var.enable_config_guardrail
}

output "raw_bucket" { value = module.pipeline.raw_bucket }
output "curated_bucket" { value = module.pipeline.curated_bucket }
output "evidence_bucket" { value = module.pipeline.evidence_bucket }
output "glue_job_name" { value = module.pipeline.glue_job_name }
output "athena_db" { value = module.pipeline.athena_db }
output "kms_key_arn" { value = module.pipeline.kms_key_arn }
output "reader_role_arn" { value = module.pipeline.reader_role_arn }
output "budget_name" { value = module.pipeline.budget_name }
output "anomaly_monitor_arn" { value = module.pipeline.anomaly_monitor_arn }
output "config_rule_name" { value = module.pipeline.config_rule_name }
