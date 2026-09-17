output "raw_bucket" { value = aws_s3_bucket.data["raw"].id }
output "curated_bucket" { value = aws_s3_bucket.data["curated"].id }
output "scripts_bucket" { value = aws_s3_bucket.data["scripts"].id }
output "evidence_bucket" { value = aws_s3_bucket.evidence.id }
output "glue_job_name" { value = aws_glue_job.transform.name }
output "athena_db" { value = aws_athena_database.curated.name }
output "kms_key_arn" { value = aws_kms_key.data.arn }
output "reader_role_arn" { value = aws_iam_role.restricted_reader.arn }
output "budget_name" { value = aws_budgets_budget.monthly.name }
output "anomaly_monitor_arn" { value = aws_ce_anomaly_monitor.cost_center.arn }
output "config_rule_name" {
  value = var.enable_config_guardrail ? aws_config_config_rule.module_signature[0].name : "disabled (set enable_config_guardrail=true)"
}
