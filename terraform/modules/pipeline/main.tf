data "aws_caller_identity" "current" {}

locals {
  suffix        = data.aws_caller_identity.current.account_id
  evidence_name = "vpl-${var.name}-evidence-${local.suffix}"

  # The three data-plane zones. for_each so encryption, public-access-block,
  # and the TLS-only policy are applied identically to every one of them.
  # Adding a zone later inherits all the controls for free.
  data_buckets = {
    raw     = "vpl-${var.name}-raw-${local.suffix}"
    curated = "vpl-${var.name}-curated-${local.suffix}"
    scripts = "vpl-${var.name}-scripts-${local.suffix}"
  }
}

# --- KMS: one customer-managed key encrypts every zone at rest ----------------
# Veeva Trust page: "AES 256 encryption ... at rest". A CMK (not the AWS-managed
# default) means the key policy is ours to control and rotation is on.
resource "aws_kms_key" "data" {
  description             = "vpl-${var.name} data-at-rest encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "data" {
  name          = "alias/vpl-${var.name}-data"
  target_key_id = aws_kms_key.data.key_id
}

# --- S3 zones (raw, curated, scripts) -----------------------------------------
resource "aws_s3_bucket" "data" {
  for_each = local.data_buckets
  bucket   = each.value
}

# Encryption at rest, every bucket, via the CMK. The policy gate counts buckets
# vs. encryption configs and fails the build if any bucket is missing one.
resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  for_each = aws_s3_bucket.data
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true # cuts KMS request cost on high-volume reads
  }
}

# No zone is ever publicly reachable.
resource "aws_s3_bucket_public_access_block" "data" {
  for_each                = aws_s3_bucket.data
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# TLS-only. Any request not over HTTPS is denied. This is `make verify` proof #1:
# a plain-HTTP GET against a zone returns 403 in the live account.
resource "aws_s3_bucket_policy" "data" {
  for_each = aws_s3_bucket.data
  bucket   = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [each.value.arn, "${each.value.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.data]
}

# Ship the Glue script up so the job can find it.
resource "aws_s3_object" "job_script" {
  bucket = aws_s3_bucket.data["scripts"].id
  key    = "transform_job.py"
  source = "${path.module}/../../../glue/transform_job.py"
  etag   = filemd5("${path.module}/../../../glue/transform_job.py")
}

# --- Evidence zone: tamper-evident audit trail --------------------------------
# Object Lock in GOVERNANCE mode + versioning means every deploy's plan lands
# here and cannot be quietly overwritten or deleted. This is the GxP / SOC 2
# change-control beat: the platform produces its own audit trail. Teardown needs
# a governance-bypass sweep, handled by scripts/purge_evidence.py in `make destroy`.
resource "aws_s3_bucket" "evidence" {
  bucket              = local.evidence_name
  object_lock_enabled = true
  force_destroy       = true
}

resource "aws_s3_bucket_versioning" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.evidence_retention_days
    }
  }
  depends_on = [aws_s3_bucket_versioning.evidence]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "evidence" {
  bucket                  = aws_s3_bucket.evidence.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.evidence.arn, "${aws_s3_bucket.evidence.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.evidence]
}

# --- Least-privilege IAM for the Glue job -------------------------------------
resource "aws_iam_role" "glue" {
  name = "vpl-${var.name}-glue-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "glue" {
  name = "vpl-${var.name}-glue-policy"
  role = aws_iam_role.glue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadWriteZones"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.data["raw"].arn, "${aws_s3_bucket.data["raw"].arn}/*",
          aws_s3_bucket.data["curated"].arn, "${aws_s3_bucket.data["curated"].arn}/*",
          aws_s3_bucket.data["scripts"].arn, "${aws_s3_bucket.data["scripts"].arn}/*",
        ]
      },
      {
        # The job reads/writes SSE-KMS objects, so it needs the key. Scoped to
        # this one CMK, nothing wider.
        Sid      = "UseDataKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [aws_kms_key.data.arn]
      },
    ]
  })
}

# --- Restricted reader: the principal that PROVES least privilege -------------
# Allowed to read the raw zone only. `make verify` assumes this role and shows it
# CAN read raw (positive control) but is DENIED on curated (proof #2). Trust page:
# "least privileged access ... enforced through automated means" - demonstrated,
# not asserted.
resource "aws_iam_role" "restricted_reader" {
  name = "vpl-${var.name}-restricted-reader"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${local.suffix}:root" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "restricted_reader" {
  name = "raw-read-only"
  role = aws_iam_role.restricted_reader.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadRawZoneOnly"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.data["raw"].arn, "${aws_s3_bucket.data["raw"].arn}/*"]
      },
      {
        # Decrypt only, so a successful raw read isn't blocked by KMS instead of
        # S3. The denial on curated is then unambiguously an IAM least-privilege
        # denial, not an encryption artifact.
        Sid      = "DecryptDataKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.data.arn]
      },
    ]
  })
}

# --- Glue transform job -------------------------------------------------------
# max_capacity is the guardrail the policy gate reads. Capped by var.glue_max_dpus.
resource "aws_glue_job" "transform" {
  name         = "vpl-${var.name}-transform"
  role_arn     = aws_iam_role.glue.arn
  glue_version = "4.0"
  max_capacity = var.glue_max_dpus

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data["scripts"].id}/transform_job.py"
    python_version  = "3"
  }

  default_arguments = {
    "--RAW_PATH"     = "s3://${aws_s3_bucket.data["raw"].id}/incoming/"
    "--CURATED_PATH" = "s3://${aws_s3_bucket.data["curated"].id}/curated/"
  }
}

# --- Athena query layer (stands in for Redshift, near zero cost) --------------
resource "aws_athena_database" "curated" {
  name   = "vpl_${var.name}_curated"
  bucket = aws_s3_bucket.data["curated"].id
}
