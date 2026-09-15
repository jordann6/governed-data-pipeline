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
        gate = GithubActions("OPA / conftest\ntags, DPU cap,\nencryption, no public")
        evidence = S3("S3 evidence zone\nObject Lock + versioned")
        tf >> Edge(label="plan (json)") >> gate
        gate >> Edge(label="apply +\ncapture plan", style="bold") >> evidence

    # --- Governance primitives ---
    kms = KMS("KMS CMK\nrotation on")
    reader = IAM("restricted-reader\nleast-privilege proof")
    airflow = Airflow("Airflow DAG\ntrigger")

    # --- Data plane ---
    with Cluster("Governed pipeline  (us-east-1)"):
        raw = S3("S3 raw")
        glue = Glue("Glue PySpark\ncapped at 2 DPUs")
        curated = S3("S3 curated\n(Parquet)")
        athena = Athena("Athena\n(Redshift stand-in)")
        raw >> glue >> curated >> athena

    # --- Wiring (governance edges unconstrained so they route cleanly) ---
    kms >> Edge(label="SSE-KMS\nevery zone", style="dashed", color="darkgreen",
                constraint="false") >> raw
    airflow >> Edge(label="starts job", constraint="false") >> glue
    reader >> Edge(label="allowed", color="darkgreen", constraint="false") >> raw
    reader >> Edge(label="DENIED (IAM)", color="firebrick", style="bold",
                   constraint="false") >> curated
