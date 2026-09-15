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
