SHELL := /bin/bash
.PHONY: init plan gate deploy demo verify evidence destroy

TF := terraform -chdir=terraform
PY := python3

init:
	$(TF) init

plan:
	$(TF) plan -out=tfplan
	$(TF) show -json tfplan > tfplan.json

# Local mirror of the CI gate. Same rules block cost (DPU cap, tags) AND security
# (encryption at rest, no public access). Requires infracost and conftest installed.
gate: plan
	infracost breakdown --path terraform || true
	conftest test tfplan.json --policy policy || (echo "POLICY GATE FAILED"; exit 1)

deploy:
	$(TF) apply tfplan
	@$(MAKE) evidence

# Capture the applied plan into the Object-Locked evidence zone. Every deploy
# leaves a tamper-evident record: the GxP / SOC 2 change-control beat.
evidence:
	@EVID=$$($(TF) output -raw evidence_bucket); \
	 TS=$$(date -u +%Y%m%dT%H%M%SZ); \
	 aws s3 cp tfplan.json s3://$$EVID/evidence/$$TS-tfplan.json >/dev/null; \
	 echo "captured plan evidence -> s3://$$EVID/evidence/$$TS-tfplan.json (object-locked, versioned)"

# Uploads sample data and runs the Glue job. RAW/JOB come from terraform outputs.
demo:
	@RAW=$$($(TF) output -raw raw_bucket); \
	 JOB=$$($(TF) output -raw glue_job_name); \
	 aws s3 cp data/sample.csv s3://$$RAW/incoming/sample.csv; \
	 echo "Starting Glue job $$JOB"; \
	 aws glue start-job-run --job-name $$JOB

# The money shot: prove the guardrails hold in the live account, not on a slide.
# Proof 1: a plain-HTTP request to a zone is denied (TLS-only, 403).
# Proof 2: the restricted-reader role CAN read raw (positive control) but is
#          DENIED on curated (least privilege enforced through automated means).
verify:
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

destroy:
	$(PY) scripts/purge_evidence.py $$($(TF) output -raw evidence_bucket 2>/dev/null) || true
	$(TF) destroy
	@echo "Confirm no lingering S3 objects, Glue jobs, or Athena results before you walk away."
