# dev: the experimentation tier. Not validated, so the guardrails are loosest
# here: a higher Glue DPU ceiling for iteration and short evidence retention.
# In a real Veeva-style layout this points at a separate dev AWS account.
environment             = "dev"
cost_center             = "platform-lab-dev"
glue_max_dpus           = 4
evidence_retention_days = 1
monthly_budget          = 50
