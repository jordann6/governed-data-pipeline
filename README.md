# Governed data pipeline

A Terraform module that stamps out an S3 to Glue to Athena pipeline with tagging, a cost ceiling, encryption, least-privilege IAM, and TLS enforcement already wired in. A policy gate in CI refuses to ship a pipeline that skips any of them.

## The problem

On a growing data team, everyone tends to build pipelines their own way. One person ships an oversized Glue job, another forgets a bucket policy, a third leaves resources untagged so nobody can trace the bill later. None of it is careless. It happens because the safe way to stand up a pipeline takes longer than the quick way, and under a deadline the quick way wins.

Two things break because of that. Spend drifts, because there is no attribution and no ceiling, and a single mis-sized job can quietly run into the thousands before anyone notices. And in a regulated environment, an unencrypted or undocumented resource is not just untidy, it is an audit finding: an unrecorded change to a controlled system.

The root cause is not any one pipeline. It is that there is no standard, enforced way to build one, so the controls stay optional and optional controls get skipped.

## The solution

Make the safe path the only path. This repo is one Terraform module that provisions a full pipeline with every control already attached, plus a CI gate that fails the build the moment a plan violates one. An engineer calls the module and gets governance for free. They cannot produce an untagged, oversized, unencrypted, or publicly reachable resource through it, because the gate rejects the plan before anything is applied.

What the module builds:

- Three S3 zones (raw, curated, scripts). Each one gets SSE-KMS encryption, a public-access block on all four settings, and a bucket policy that denies any request not made over TLS.
- One customer-managed KMS key with rotation on, used across every zone, so the key policy and rotation are ours to control rather than the account default.
- A Glue PySpark job capped at 2 DPUs, on an IAM role scoped to only the buckets and the one key it actually touches.
- An Athena database over the curated zone. It stands in for Redshift and costs almost nothing to query.
- An Object-Locked, versioned evidence bucket. Every deploy writes its Terraform plan there, where it cannot be overwritten or deleted.
- A restricted-reader IAM role that exists only to prove least privilege is real, not asserted.
- A per-tier AWS Budget and a Cost Anomaly Detection monitor, both scoped to this pipeline's `cost_center` tag, so cost has an owner and the loop is closed after apply, not just at plan time.
- An optional AWS Config rule (off by default) that flags any resource in the account missing the module's signature tag, so pipelines built outside the paved road get caught.

The transform itself is deliberately small: read raw CSV, drop empty rows, add a load timestamp, write Parquet partitioned by date. The pipeline is the point, not the ETL.

## FinOps as a practice, not just a ceiling

A DPU cap stops one oversized job before apply. That is prevention, and it is necessary, but a team that actually *practices* FinOps needs cost to be visible at the moment of decision and owned after the fact. This repo closes that loop at three points in the lifecycle:

- **At the pull request, cost is made visible.** The CI gate runs `infracost` and posts the monthly-cost diff as a PR comment, so every reviewer sees "+$14/mo" before merge. Cost becomes a review criterion, not an after-the-fact surprise. That is the mindful half.
- **At the gate, the budget is a blocking control.** `infracost breakdown --format json` feeds the same conftest gate, and a per-tier dollar budget (dev loose, prod tightest, the same tier-aware idea as the DPU cap) rejects a plan whose estimate is over budget. Cost is now enforced in the same class as encryption, not merely displayed.
- **After apply, the loop is closed.** An AWS Budget alerts at 80% of actual and 100% of forecast spend, and Cost Anomaly Detection flags a job that suddenly runs far past its usual cost, which no plan-time gate can predict. Both are scoped to the `cost_center` tag the gate already requires.

The `cost_center` tag is the spine of all of this. It is required by the gate, it scopes the budget and the anomaly monitor, and `make showback` slices month-to-date spend by it, so every dollar maps to an owner. Attribution is what turns "we care about cost" into a ledger someone is accountable to.

## Making sure everyone is on the paved road

The module and the CI gate only govern pipelines built *through* this repo. They do nothing about the engineer who opens the console and clicks out a Glue job, or calls the CLI directly. Prevention in the module needs a detective backstop at the account level, and adoption itself needs to ride with the module rather than depend on each team re-wiring the gate. Three things make that real:

- **The guardrails ride with the module.** `.github/workflows/gate.yml` is a reusable workflow (`workflow_call`), so a consuming repo inherits the exact same gate with one line (`uses: jordann6/governed-data-pipeline/.github/workflows/gate.yml@v1`) instead of copying (and drifting from) the policy. Pair it with a branch-protection rule requiring the `governance` check and the gate becomes un-mergeable-around.
- **Every module resource is signed.** The provider stamps `managed_by = "pipeline-module"` on everything the module creates. That tag is the signature the detective control keys on.
- **The account catches bypasses.** An AWS Config `REQUIRED_TAGS` rule (in `adoption.tf`, behind `enable_config_guardrail`, off by default because Config recording is account-global and adds cost) flags any resource missing that signature. Anything built by ClickOps or a raw CLI call has no `managed_by=pipeline-module` tag, so it shows up NON_COMPLIANT. Module = prevention, Config = detection: defense in depth, so "everyone uses the recommended pipeline" is enforceable instead of merely requested.

## Architecture

![Architecture: S3 to Glue to Athena with a KMS key, an Airflow trigger, an Object-Locked evidence zone, a CI policy gate (with an Infracost budget gate) that blocks non-compliant plans before apply, a post-apply FinOps loop of AWS Budgets and Cost Anomaly Detection scoped by cost_center, and an AWS Config backstop that flags off-module resources](docs/architecture.png)

The diagram is generated from code (`docs/architecture.py`, official AWS icons via the `diagrams` library) so it stays in sync with the module. Text fallback:

```
   sample data
       |
       v
  +-----------+      +-------------------+      +----------------------+
  |  S3 raw   | ---> |  Glue (PySpark)   | ---> |  S3 curated (Parquet)|
  +-----------+      +-------------------+      +----------------------+
       ^                     ^                            |
       |                     |                            v
  Terraform + KMS      triggered by an              Athena query layer
  (TLS-only policy)    Airflow DAG                  (Redshift stand-in)

  Every zone:      SSE-KMS at rest, public-access-block, DenyInsecureTransport
  Evidence zone:   Object-Locked and versioned. Each deploy's plan lands here.
  CI gate:         conftest/OPA blocks tags, cost, encryption, and public-access
                   violations at the pull request, before apply. Infracost posts
                   the monthly-cost diff on the PR and enforces a per-tier budget.
  FinOps loop:     AWS Budgets (80% actual / 100% forecast) + Cost Anomaly
                   Detection, both scoped to the cost_center tag, close the loop
                   after apply.
  Adoption:        every module resource is tagged managed_by=pipeline-module; an
                   AWS Config REQUIRED_TAGS rule flags anything in the account that
                   is not, catching pipelines built outside the module.
```

## Compliance mapping

This is a reference lab, not a certified system, but each control is the concrete implementation of a requirement that a regulated SaaS lives under. The columns below tie each one to SOC 2 Type II, ISO 27001 (and 27017/27018 for cloud), and GxP change-control expectations, including the 21 CFR Part 11 audit-trail requirement.

| Control | How it is implemented | What it satisfies |
|---|---|---|
| Attribution | `default_tags` on the provider; the gate rejects any untagged resource | SOC 2 accountability, FinOps ownership |
| Cost ceiling | per-tier Glue DPU cap (2 by default, tighter for prod); the gate rejects an oversized job | operational discipline, spend control |
| Cost budget | per-tier dollar budget; Infracost estimate in CI both comments on the PR and fails an over-budget plan | preventive FinOps, spend control |
| Cost feedback loop | AWS Budgets (80% actual / 100% forecast) + Cost Anomaly Detection, scoped by `cost_center` | detective FinOps, ongoing accountability |
| Paved-road adoption | every resource signed `managed_by=pipeline-module`; an AWS Config rule flags anything without it | standardization, drift/shadow-IT detection |
| Encryption at rest | one CMK, SSE-KMS on every zone, rotation enabled | SOC 2 CC6.1, ISO 27001 cryptography, "AES 256 encryption at rest" |
| Encryption in transit | `DenyInsecureTransport` on every bucket | SOC 2 CC6.7, TLS 1.2 minimum |
| No public data | public-access-block, all four settings, on every zone | SOC 2 CC6, data confidentiality |
| Least privilege | scoped IAM per role; a restricted-reader role proves it live | SOC 2 CC6.3, "least privileged access enforced through automated means" |
| Change control | Object-Locked evidence zone captures every deploy's plan | SOC 2 CC8.1 change management, GxP / 21 CFR Part 11 audit trail |
| Enforcement | conftest gate in CI blocks all of the above at the PR | SOC 2 CC8.1, controls that cannot be skipped |

The point of the last row is that the same gate that stops a surprise bill also produces the record change-control needs. Cost hygiene and compliance turn out to be one control, not two.

## Enforcement, and how to see it

The gate runs twice: once locally before you push, once in CI on the pull request. It reads the Terraform plan as JSON and checks tags, a per-tier Glue DPU ceiling, encryption on every bucket, no public access, and a prod-only evidence-retention floor. It also reads the Infracost breakdown and rejects a plan whose estimated monthly cost is over the tier's dollar budget. `policy/tags.rego` holds the rules.

To watch it fail on purpose, bump the Glue job past 2 DPUs, remove an encryption block, flip a public-access flag, or push the plan's estimate past the tier budget, then run `make gate`. The plan is rejected before a dollar is spent or a bucket is exposed.

Two of the controls are also proven in the live account by `make verify`:

- TLS only. A plain-HTTP request to a zone returns `403`, denied by the bucket policy.
- Least privilege. The restricted-reader role reads the raw zone (the positive control) but is denied on curated. The denial is an IAM decision, not an encryption artifact, because the role holds `kms:Decrypt`. Least privilege is demonstrated, not claimed.

## Running it

```bash
make init       # terraform init
make gate       # plan, then conftest: security + tags + DPU cap AND a per-tier dollar budget (via infracost)
make deploy     # terraform apply, then capture the plan into the evidence zone
make demo       # upload sample data, run the Glue job
make verify     # prove TLS-only and least privilege in the live account
make showback   # month-to-date spend sliced by the cost_center tag (attribution as a ledger)
make destroy    # sweep the Object-Locked evidence zone, then terraform destroy
```

The same gate runs in CI as a reusable workflow (`.github/workflows/gate.yml`): on a pull request it posts the Infracost cost diff as a comment and blocks an over-budget or non-compliant plan, and any consuming repo inherits it with a one-line `uses:` reference so the guardrails ride with the module.

These run against the `sandbox` tier by default; pass `ENV=dev|test|prod` to target another (see Environments below).

Prerequisites: AWS credentials (region defaults to `us-east-1`), Terraform, the AWS CLI, `conftest`, `python3` with `boto3` for the teardown sweep, and `curl`. The caller must be able to assume the restricted-reader role, which any account admin can. `infracost` is optional; the gate skips it cleanly if it is not installed.

## Environments (sandbox / dev / test / prod)

The pipeline is one reusable module, so every tier is the same module promoted
per tier, not a copy. Each tier gets its own Terraform workspace (separate state,
real isolation) and its own var-file under `terraform/envs/`, and the environment
name is baked into every resource name so tiers never collide even in a single
account. In a real Veeva-style layout each tier is a separate AWS account and the
account id already disambiguates.

Every `make` target takes an `ENV`, which defaults to `sandbox`:

```bash
make gate ENV=dev      # plan + policy check against the dev tier
make deploy ENV=prod   # apply the prod tier into its own workspace
make destroy ENV=test  # tear down just the test tier
```

The policy gate is tier-aware: it reads the `environment` tag and tightens by
tier. dev allows a higher Glue DPU ceiling for experimentation; test and prod
are capped tighter; and prod, as a validated environment, additionally requires
the Object-Lock evidence retention to clear an audit floor. So the same gate that
blocks the accidental $15k job also enforces stricter change-control on prod than
on dev, which is exactly what a GxP / SOC 2 shop needs.

## Cost

Multi-environment structure (the var-files, workspaces, and tier-aware gate) adds
no cost on its own; billing starts only when you `terraform apply` a given
environment. The one standing charge per live environment is its KMS key, about a
dollar a month, so three environments running at once is a few dollars a month
idle. You do not need them all live at once to prove the pattern.

Everything is serverless or local, and nothing is always-on. Left running for a full week the bill stays well under a dollar. S3 storage is pennies, the Glue job is a few cents per run at 2 DPUs, Athena is cents per query, and the Airflow DAG runs locally for free. The only standing charge is the KMS key at about a dollar a month. Athena instead of a Redshift cluster and local Airflow instead of MWAA (which would be roughly $350 a month for the same DAG) are deliberate choices: the idle cost was engineered down, not left to chance.

The FinOps loop is free: AWS Budgets and Cost Anomaly Detection carry no charge. The one add-on that does cost money is the adoption backstop, so it is off by default (`enable_config_guardrail = false`): an AWS Config recorder bills per configuration item recorded, which is why you turn it on in a single governance account to prove the org-level control rather than in every tier.

## Layout

```
terraform/                 provider default_tags, the module call, outputs
  envs/{sandbox,dev,test,prod}.tfvars  per-tier variables (incl. monthly_budget) promoted through workspaces
  modules/pipeline/        the reusable module: KMS, S3 zones, hardening,
                           IAM, evidence zone, Glue job, Athena database
    finops.tf              per-tier AWS Budget + Cost Anomaly Detection, scoped by cost_center
    adoption.tf            optional AWS Config REQUIRED_TAGS rule that flags off-module resources
glue/transform_job.py      PySpark: raw CSV to curated Parquet
airflow/dags/              the DAG that triggers the Glue job, portable to MWAA
policy/tags.rego           the conftest/OPA gate: tags, DPU cap, per-tier $ budget, encryption, public access
.github/workflows/gate.yml reusable CI gate: Infracost PR comment + the conftest policy check
scripts/purge_evidence.py  governance-bypass sweep so destroy can remove the locked zone
data/sample.csv            a small input so the demo runs in seconds
```

## Scope and limitations

This is a proof artifact, not a 17TB production system. The pattern holds at scale, but the rollout would sequence by blast radius and the Glue and warehouse tiers would be sized for real volume. The MWAA and Glue depth here is lighter than the S3, IaC, and policy depth on purpose: the module and the gate are the parts worth showing.
