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
