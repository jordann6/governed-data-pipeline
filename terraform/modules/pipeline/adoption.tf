# =============================================================================
# Adoption: guarantee people are actually ON the paved road.
#
# The module and the CI gate only govern pipelines built THROUGH this repo. They
# do nothing about the engineer who opens the console and clicks out a Glue job,
# or calls the AWS CLI directly. Prevention-in-the-module needs a detective
# backstop at the account level so a bypass is CAUGHT even when nobody used the
# module.
#
# Every resource this module creates carries the signature tag
# managed_by = "pipeline-module" (set in the provider default_tags). This AWS
# Config rule flags any resource in the account that is MISSING that signature,
# i.e. anything created outside the paved road. Module = prevention; Config =
# detection. Defense in depth.
#
# Gated behind var.enable_config_guardrail (default false) because a Config
# recorder is account-global (one per region) and adds cost. Turn it on in a
# single governance account to prove the org-level control.
# =============================================================================

# A dedicated bucket for Config's configuration snapshots and history.
resource "aws_s3_bucket" "config" {
  count         = var.enable_config_guardrail ? 1 : 0
  bucket        = "${local.prefix}-config-${local.suffix}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "config" {
  count                   = var.enable_config_guardrail ? 1 : 0
  bucket                  = aws_s3_bucket.config[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The role Config assumes to read the account's resource configuration.
resource "aws_iam_role" "config" {
  count = var.enable_config_guardrail ? 1 : 0
  name  = "${local.prefix}-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  count      = var.enable_config_guardrail ? 1 : 0
  role       = aws_iam_role.config[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# Config needs write access to its delivery bucket.
resource "aws_iam_role_policy" "config_s3" {
  count = var.enable_config_guardrail ? 1 : 0
  name  = "config-delivery"
  role  = aws_iam_role.config[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetBucketAcl"]
        Resource = [aws_s3_bucket.config[0].arn, "${aws_s3_bucket.config[0].arn}/*"]
      },
    ]
  })
}

resource "aws_config_configuration_recorder" "main" {
  count    = var.enable_config_guardrail ? 1 : 0
  name     = "${local.prefix}-recorder"
  role_arn = aws_iam_role.config[0].arn
  recording_group {
    all_supported = true
  }
}

resource "aws_config_delivery_channel" "main" {
  count          = var.enable_config_guardrail ? 1 : 0
  name           = "${local.prefix}-delivery"
  s3_bucket_name = aws_s3_bucket.config[0].id
  depends_on     = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  count      = var.enable_config_guardrail ? 1 : 0
  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# The detective control itself: REQUIRED_TAGS flags any resource missing the
# module signature. Anything created outside the paved road (ClickOps, raw CLI)
# has no managed_by=pipeline-module tag, so it shows up NON_COMPLIANT here. That
# is how "everyone uses the recommended pipeline" becomes enforceable instead of
# merely requested.
resource "aws_config_config_rule" "module_signature" {
  count = var.enable_config_guardrail ? 1 : 0
  name  = "${local.prefix}-must-use-pipeline-module"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  input_parameters = jsonencode({
    tag1Key   = "managed_by"
    tag1Value = "pipeline-module"
    tag2Key   = "cost_center"
  })

  depends_on = [aws_config_configuration_recorder_status.main]
}
