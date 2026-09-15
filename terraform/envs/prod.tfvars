# prod: the validated tier. Strictest guardrails: the smallest Glue ceiling and
# the longest Object-Lock evidence retention, because in a GxP / SOC 2 shop prod
# is a validated environment and every change must leave a durable audit trail.
# 30 days here to keep the demo cheap; a real validated env would be years.
# Separate, locked-down account in a real layout.
environment             = "prod"
cost_center             = "platform-lab-prod"
glue_max_dpus           = 2
evidence_retention_days = 30
