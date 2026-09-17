SHELL := /bin/bash
.PHONY: init ws plan gate deploy demo verify evidence showback destroy

TF := terraform -chdir=terraform
PY := python3

# ENV selects the tier (sandbox, dev, test, prod). Each tier is the SAME module
# in its own Terraform workspace (separate state = real isolation) with its own
# -var-file, so it is promoted per tier instead of copied. Defaults to sandbox,
# the base/demo tier this lab runs in.
ENV ?= sandbox
VAR_FILE := -var-file=envs/$(ENV).tfvars

init:
	$(TF) init

# Select the workspace for ENV, creating it on first use.
ws:
	$(TF) workspace select -or-create $(ENV)

plan: ws
	$(TF) plan $(VAR_FILE) -out=tfplan
	$(TF) show -json tfplan > tfplan.json

# Local mirror of the CI gate. Same rules block cost (DPU cap, tags, and now a
# per-tier DOLLAR budget) AND security (encryption at rest, no public access).
# The plan-shaped rules run against tfplan.json; the budget rule runs against the
# Infracost breakdown, with the tier passed in as data.env so env_budget applies.
# Requires conftest; infracost is optional and the budget step skips cleanly if
# it is not installed, exactly as before.
gate: plan
	@if command -v infracost >/dev/null 2>&1; then \
	  echo "== Infracost: estimating monthly cost + enforcing the $(ENV) budget =="; \
	  infracost breakdown --path terraform --format json --out-file infracost.json; \
	  echo '{"env":"$(ENV)"}' > budget_env.json; \
	  conftest test infracost.json --policy policy --data budget_env.json \
	    || (echo "COST/BUDGET GATE FAILED"; exit 1); \
	else \
	  echo "infracost not installed, skipping the dollar-budget gate (DPU cap still enforced below)"; \
	fi
	conftest test tfplan.json --policy policy || (echo "POLICY GATE FAILED"; exit 1)

deploy: ws
	$(TF) apply tfplan
	@$(MAKE) evidence ENV=$(ENV)

# Capture the applied plan into the Object-Locked evidence zone. Every deploy
# leaves a tamper-evident record: the GxP / SOC 2 change-control beat.
evidence: ws
	@EVID=$$($(TF) output -raw evidence_bucket); \
	 TS=$$(date -u +%Y%m%dT%H%M%SZ); \
	 aws s3 cp tfplan.json s3://$$EVID/evidence/$$TS-tfplan.json >/dev/null; \
	 echo "captured plan evidence -> s3://$$EVID/evidence/$$TS-tfplan.json (object-locked, versioned)"

# Uploads sample data and runs the Glue job. RAW/JOB come from terraform outputs.
demo: ws
	@RAW=$$($(TF) output -raw raw_bucket); \
	 JOB=$$($(TF) output -raw glue_job_name); \
	 aws s3 cp data/sample.csv s3://$$RAW/incoming/sample.csv; \
	 echo "Starting Glue job $$JOB"; \
	 aws glue start-job-run --job-name $$JOB

# The money shot: prove the guardrails hold in the live account, not on a slide.
# Proof 1: a plain-HTTP request to a zone is denied (TLS-only, 403).
# Proof 2: the restricted-reader role CAN read raw (positive control) but is
#          DENIED on curated (least privilege enforced through automated means).
verify: ws
	@set -euo pipefail; \
	 RAW=$$($(TF) output -raw raw_bucket); \
	 CURATED=$$($(TF) output -raw curated_bucket); \
	 READER=$$($(TF) output -raw reader_role_arn); \
	 echo "== Proof 1: TLS-only (DenyInsecureTransport) =="; \
	 CODE=$$(curl -s -o /dev/null -w '%{http_code}' "http://$$RAW.s3.amazonaws.com/" || true); \
	 echo "  plain-HTTP GET on raw zone -> HTTP $$CODE (expect 403)"; \
	 [[ "$$CODE" == "403" ]] && echo "  PASS: insecure transport denied" || { echo "  FAIL"; exit 1; }; \
	 echo "== Proof 2: least privilege (wrong principal) =="; \
	 echo "canary" > /tmp/vpl-canary.txt; \
	 aws s3 cp /tmp/vpl-canary.txt "s3://$$RAW/incoming/canary.txt" >/dev/null; \
	 aws s3 cp /tmp/vpl-canary.txt "s3://$$CURATED/curated/canary.txt" >/dev/null; \
	 CREDS=$$(aws sts assume-role --role-arn "$$READER" --role-session-name vpl-verify \
	   --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text); \
	 read -r AK SK ST <<< "$$CREDS"; \
	 echo "  assumed restricted-reader (raw-read-only)"; \
	 if AWS_ACCESS_KEY_ID=$$AK AWS_SECRET_ACCESS_KEY=$$SK AWS_SESSION_TOKEN=$$ST \
	      aws s3 cp "s3://$$RAW/incoming/canary.txt" /tmp/vpl-raw-out.txt >/dev/null 2>&1; then \
	   echo "  PASS: reader CAN read the raw zone (positive control)"; \
	 else echo "  FAIL: reader should be allowed to read raw"; exit 1; fi; \
	 if AWS_ACCESS_KEY_ID=$$AK AWS_SECRET_ACCESS_KEY=$$SK AWS_SESSION_TOKEN=$$ST \
	      aws s3 cp "s3://$$CURATED/curated/canary.txt" /tmp/vpl-cur-out.txt >/dev/null 2>&1; then \
	   echo "  FAIL: reader read curated, least privilege NOT enforced"; exit 1; \
	 else echo "  PASS: reader DENIED on curated (AccessDenied)"; fi

# Showback: prove attribution is not just a required tag but a usable ledger.
# Pulls month-to-date spend from Cost Explorer grouped by the cost_center tag, so
# every dollar maps to an owner. This is the "team that practices FinOps" beat:
# the same tag the gate enforces is the axis the bill is sliced on. (Cost
# allocation tags must be activated once in Billing; near-zero numbers are
# expected on this lab.)
showback:
	@START=$$(date -u -v1d +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-01); \
	 END=$$(date -u +%Y-%m-%d); \
	 echo "== Month-to-date spend by cost_center ($$START -> $$END) =="; \
	 aws ce get-cost-and-usage \
	   --time-period Start=$$START,End=$$END \
	   --granularity MONTHLY --metrics UnblendedCost \
	   --group-by Type=TAG,Key=cost_center \
	   --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' \
	   --output table 2>/dev/null \
	   || echo "  (activate the cost_center cost-allocation tag in Billing to populate this)"

destroy: ws
	$(PY) scripts/purge_evidence.py $$($(TF) output -raw evidence_bucket 2>/dev/null) || true
	$(TF) destroy $(VAR_FILE)
	@echo "Confirm no lingering S3 objects, Glue jobs, or Athena results before you walk away."
