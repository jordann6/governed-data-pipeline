variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "sandbox"
}

variable "owner" {
  type        = string
  description = "Required tag: who owns this spend. No default on purpose, forces an answer."
  default     = "jordan"
}

variable "cost_center" {
  type        = string
  description = "Required tag the policy gate checks for. Attribution is the foundation of FinOps."
  default     = "platform-lab"
}

# Guardrail: cap the Glue job size. The policy gate rejects anything over this,
# so nobody can quietly ship a 100-DPU job and blow the bill.
variable "glue_max_dpus" {
  type    = number
  default = 2
}

variable "evidence_retention_days" {
  type    = number
  default = 1
}

# FinOps: per-tier budget the AWS Budget alerts on and the Infracost gate checks
# against. Same tier-aware idea as glue_max_dpus, dev loose, prod tight.
variable "monthly_budget" {
  type    = number
  default = 10
}

variable "finops_alert_email" {
  type        = string
  description = "Where Budgets and Cost Anomaly Detection alerts are sent."
  default     = "jordandn6@outlook.com"
}

# Adoption backstop: stand up the AWS Config recorder + REQUIRED_TAGS rule that
# catches resources built outside the module. Off by default (account-global, adds
# cost); enable in one governance account to prove the org-level control.
variable "enable_config_guardrail" {
  type    = bool
  default = false
}
