# =============================================================================
# FinOps: make cost a PRACTICE, not just a ceiling.
#
# The DPU cap in the policy gate is prevention: it stops the oversized job before
# apply. That is necessary but not sufficient. A team that "cares about cost" also
# needs the loop closed AFTER apply, and needs a dollar owner for every resource.
# This file adds the two halves the gate cannot give you:
#
#   1. A per-tier AWS Budget, scoped by the cost_center tag, that alerts at 80%
#      actual and 100% forecast. Attribution -> a real budget per owner (showback).
#   2. Cost Anomaly Detection on the same cost_center, so a job that suddenly runs
#      500x its usual spend is flagged within a day, which no plan-time gate can
#      predict.
#
# Budgets and Cost Anomaly Detection are free, so these are always on. The DPU cap
# is the "before" control; these are the "after" control. Together they are the
# preventive + detective FinOps loop.
# =============================================================================

# Per-tier budget, scoped to THIS pipeline's cost_center. The tag the policy gate
# already requires is what makes this possible: attribution is the foundation the
# budget stands on. dev gets a looser number, prod a tighter one, set per tier.
resource "aws_budgets_budget" "monthly" {
  name         = "${local.prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Only count spend tagged to this pipeline's cost center. Showback in one line:
  # the budget bills exactly what this owner is responsible for, nothing else.
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:cost_center$%s", var.cost_center)]
  }

  # Warn at 80% of ACTUAL spend: you are close, be mindful.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.finops_alert_email]
  }

  # Alarm at 100% of FORECAST spend: you are on track to blow the budget this
  # month. Forecast, not actual, so it fires BEFORE the overspend, not after.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.finops_alert_email]
  }
}

# Cost Anomaly Detection on the same cost_center. This is the control the gate
# structurally cannot be: it catches spend that the plan looked fine but the
# runtime did not, e.g. a job triggered in a loop, a query scanning far more than
# expected. Custom monitor scoped to the tag so the signal is per-owner, not noise
# from the whole account.
resource "aws_ce_anomaly_monitor" "cost_center" {
  name         = "${local.prefix}-anomaly"
  monitor_type = "CUSTOM"

  monitor_specification = jsonencode({
    Tags = {
      Key          = "cost_center"
      Values       = [var.cost_center]
      MatchOptions = ["EQUALS"]
    }
  })
}

resource "aws_ce_anomaly_subscription" "cost_center" {
  name      = "${local.prefix}-anomaly-sub"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.cost_center.arn]

  subscriber {
    type    = "EMAIL"
    address = var.finops_alert_email
  }

  # Only page a human once the anomaly's dollar impact clears a floor, so the
  # loop stays credible and does not cry wolf on rounding noise.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = ["10"]
    }
  }
}
