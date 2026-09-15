# Cost + security policy gate, run by conftest against `terraform show -json tfplan`.
# This is the "step that can't be skipped": CI fails here before anything is applied.
package main

import rego.v1

required_tags := {"project", "environment", "owner", "cost_center"}

max_glue_dpus := 2

# Deny any Glue job larger than the cap. This is how you stop the 100-DPU accident.
deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "aws_glue_job"
	capacity := rc.change.after.max_capacity
	capacity > max_glue_dpus
	msg := sprintf("Glue job '%s' requests %v DPUs, over the cap of %v", [rc.name, capacity, max_glue_dpus])
}

# Deny taggable resources missing a required tag. Checks tags_all (default_tags merged in).
deny contains msg if {
	rc := input.resource_changes[_]
	tags := object.get(rc.change.after, "tags_all", {})
	missing := required_tags - {k | some k, _ in tags}
	count(missing) > 0
	count(tags) > 0 # only enforce on resources that actually carry tags
	msg := sprintf("Resource '%s' is missing required tags: %v", [rc.address, missing])
}

# --- Security controls: the SAME gate that enforces cost enforces encryption
# and no-public-access. In a GxP / SOC 2 shop, an unencrypted or public bucket
# is an audit finding, so it must be blocked at the PR, not caught later.

# Every S3 bucket must have a server-side encryption configuration. Enforced by
# invariant: the count of buckets must equal the count of encryption configs.
deny contains msg if {
	buckets := [rc | some rc in input.resource_changes; rc.type == "aws_s3_bucket"]
	sse := [rc | some rc in input.resource_changes; rc.type == "aws_s3_bucket_server_side_encryption_configuration"]
	count(buckets) != count(sse)
	msg := sprintf("Found %v S3 buckets but %v encryption configs; every bucket must be encrypted at rest", [count(buckets), count(sse)])
}

# Public access must be fully blocked on every bucket that declares a block.
deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "aws_s3_bucket_public_access_block"
	flag := ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"][_]
	rc.change.after[flag] != true
	msg := sprintf("Public-access-block '%s' has %s != true; data zones must never be publicly reachable", [rc.address, flag])
}
