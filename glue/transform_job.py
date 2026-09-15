"""Glue PySpark job: read raw CSV from the raw zone, clean it, write Parquet to curated.

This is deliberately simple. The point of the lab is the guardrails and the paved road
around the pipeline, not the transform logic itself. In the panel, use this to talk about
why Glue does the heavy lifting and Airflow only orchestrates.
"""
import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ["RAW_PATH", "CURATED_PATH"])
sc = SparkContext()
glue = GlueContext(sc)
spark = glue.spark_session

# Read raw CSV from the landing zone.
df = spark.read.option("header", "true").csv(args["RAW_PATH"])

# Minimal, honest transform: drop empties, standardize a timestamp, add a load date.
clean = (
    df.dropna(how="all")
      .withColumn("ingested_at", F.current_timestamp())
      .withColumn("load_date", F.current_date())
)

# Write Parquet, partitioned by load_date, so Athena/Redshift reads stay cheap.
(
    clean.write
    .mode("append")
    .partitionBy("load_date")
    .parquet(args["CURATED_PATH"])
)
