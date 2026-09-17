# sandbox: the personal/demo tier this lab runs in. Same shape as the other
# tiers so nothing is a special case; guardrails match test/prod (DPU 2) with
# short evidence retention since it holds no real data.
environment             = "sandbox"
cost_center             = "platform-lab-sandbox"
glue_max_dpus           = 2
evidence_retention_days = 1
monthly_budget          = 10
