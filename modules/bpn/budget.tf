
data "aws_iam_role" "budgets_role" {
  name = "BudgetsRole"
}

resource "aws_budgets_budget" "monthly_cost_budget" {
  name              = "Budget"
  budget_type       = "COST"
  limit_amount      = "50.0"
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-31_21:00"

  filter_expression {
    not {
      dimensions {
        key = "RECORD_TYPE"
        values = ["Credit", "Refund"]
      }
    }
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 50
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 85
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_email_addresses = [var.notification_email]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_email_addresses = [var.notification_email]
  }
}

resource "aws_budgets_budget_action" "stop_ec2_action" {
  budget_name        = aws_budgets_budget.monthly_cost_budget.name
  action_type        = "RUN_SSM_DOCUMENTS"
  approval_model     = "AUTOMATIC"
  execution_role_arn = data.aws_iam_role.budgets_role.arn
  notification_type  = "FORECASTED"

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 85
  }

  definition {
    ssm_action_definition {
      action_sub_type = "STOP_EC2_INSTANCES"
      region          = "sa-east-1"
      instance_ids    = [aws_instance.instance.id]
    }
  }

  subscriber {
    address           = var.notification_email
    subscription_type = "EMAIL"
  }
}