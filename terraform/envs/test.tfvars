# test: the pre-prod / validation tier. Guardrails tighten toward prod so a
# change is proven under prod-like policy before it is promoted. Separate
# account in a real layout.
environment             = "test"
cost_center             = "platform-lab-test"
glue_max_dpus           = 2
evidence_retention_days = 7
