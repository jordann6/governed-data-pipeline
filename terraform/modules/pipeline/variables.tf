variable "name" {
  type        = string
  description = "Pipeline name, used to prefix all resources."
}

variable "environment" {
  type = string
}

variable "glue_max_dpus" {
  type        = number
  description = "Ceiling on Glue capacity. The policy gate enforces this so no oversized jobs ship."
  default     = 2
}

variable "evidence_retention_days" {
  type        = number
  description = "Object Lock GOVERNANCE retention on the evidence zone. Short for the demo; production would be months."
  default     = 1
}

# --- FinOps: attribution -> budget -> anomaly, so cost is a practice, not a cap.
variable "cost_center" {
  type        = string
  description = "The cost-allocation tag value this pipeline bills to. Scopes the budget and anomaly monitor so every dollar has an owner (showback)."
  default     = "platform-lab"
}

variable "monthly_budget" {
  type        = number
  description = "Per-tier monthly budget in USD. Drives AWS Budgets alerts and the Infracost gate. dev loose, prod tight, same as the DPU cap."
  default     = 10
}

variable "finops_alert_email" {
  type        = string
  description = "Where Budgets and Cost Anomaly Detection alerts land. Closes the loop after apply, not just at plan time."
  default     = "jordandn6@outlook.com"
}

# --- Adoption: the detective backstop that catches pipelines built OUTSIDE the
# module. Off by default because AWS Config recording is account-global and adds
# cost; flip it on in one account to prove the org-level control.
variable "enable_config_guardrail" {
  type        = bool
  description = "Stand up an AWS Config recorder + REQUIRED_TAGS rule that flags any resource missing the module signature tag (managed_by=pipeline-module). Detects ClickOps / off-module resources."
  default     = false
}
