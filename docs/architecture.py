#!/usr/bin/env python3
"""Architecture diagram (as code) for the governed data pipeline.

Renders docs/architecture.png using official AWS service icons. Kept as code so the
diagram is reproducible and version-controlled alongside the infrastructure it depicts.

    pip install diagrams        # requires graphviz on PATH (brew install graphviz)
    python3 docs/architecture.py

Everything here mirrors what terraform/modules/pipeline actually provisions.
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.storage import S3
from diagrams.aws.analytics import Glue, Athena
from diagrams.aws.security import KMS, IAM
from diagrams.aws.management import Organizations, Config
from diagrams.aws.cost import Budgets, CostExplorer
from diagrams.aws.general import General
from diagrams.onprem.iac import Terraform
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.workflow import Airflow

graph_attr = {
    "fontsize": "16",
    "labelloc": "t",
    "pad": "0.8",
    "nodesep": "0.9",
    "ranksep": "1.4",
    "splines": "spline",
    "bgcolor": "white",
}
edge_attr = {"fontsize": "13"}

with Diagram(
    "Governed data pipeline",
    filename="docs/architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    edge_attr=edge_attr,
):
    # --- Control plane: the gate runs before anything applies ---
    with Cluster("CI policy gate  (runs before apply, blocks non-compliant plans)"):
        tf = Terraform("Terraform\nmodule call")
        infracost = GithubActions("Infracost\nPR cost comment\n+ per-tier $ budget gate")
        gate = GithubActions("OPA / conftest\ntags, per-tier DPU cap,\nper-tier $ budget,\nencryption, no public,\nprod retention floor")
        evidence = S3("S3 evidence zone\nObject Lock + versioned")
        tiers = Organizations("per tier:\nsandbox / dev / test / prod\n(workspace or account)")
        tf >> Edge(label="plan (json)") >> gate
        infracost >> Edge(label="monthly $\nestimate") >> gate
        gate >> Edge(label="apply +\ncapture plan", style="bold") >> evidence
        gate >> Edge(label="promoted\nper tier", style="dashed", color="darkblue") >> tiers

    # --- Governance primitives ---
    kms = KMS("KMS CMK\nrotation on")
    reader = IAM("restricted-reader\nleast-privilege proof")
    airflow = Airflow("Airflow DAG\ntrigger")

    # --- Data plane ---
    with Cluster("Governed pipeline  (one module, promoted per tier; us-east-1)"):
        raw = S3("S3 raw")
        glue = Glue("Glue PySpark\ncapped at 2 DPUs")
        curated = S3("S3 curated\n(Parquet)")
        athena = Athena("Athena\n(Redshift stand-in)")
        raw >> glue >> curated >> athena

    # --- FinOps loop: after apply, close the loop the gate cannot ---
    with Cluster("FinOps loop  (after apply, scoped by cost_center; free)"):
        budgets = Budgets("AWS Budgets\n80% actual / 100% forecast")
        anomaly = CostExplorer("Cost Anomaly\nDetection")

    # --- Adoption backstop: detect pipelines built OUTSIDE the module ---
    with Cluster("Adoption backstop  (detective)"):
        offmodule = General("ClickOps /\noff-module resource")
        config = Config("AWS Config\nREQUIRED_TAGS:\nmanaged_by=pipeline-module")

    # --- Wiring (governance edges unconstrained so they route cleanly) ---
    kms >> Edge(label="SSE-KMS\nevery zone", style="dashed", color="darkgreen",
                constraint="false") >> raw
    airflow >> Edge(label="starts job", constraint="false") >> glue
    reader >> Edge(label="allowed", color="darkgreen", constraint="false") >> raw
    reader >> Edge(label="DENIED (IAM)", color="firebrick", style="bold",
                   constraint="false") >> curated

    # FinOps loop watches the tier's tagged spend and pages the owner.
    glue >> Edge(label="tagged spend", style="dashed", color="darkorange",
                 constraint="false") >> budgets
    glue >> Edge(style="dashed", color="darkorange", constraint="false") >> anomaly

    # The Config rule catches anything missing the module signature tag.
    offmodule >> Edge(label="NON_COMPLIANT", color="firebrick", style="bold",
                      constraint="false") >> config
