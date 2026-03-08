
resource "aws_budgets_budget_action" "stop_ec2_action" {
  budget_name        = var.budget_name
  action_type        = "RUN_SSM_DOCUMENTS"
  approval_model     = "AUTOMATIC"
  execution_role_arn = var.budgets_role_arn
  notification_type  = "FORECASTED"

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 85
  }

  definition {
    ssm_action_definition {
      action_sub_type = "STOP_EC2_INSTANCES"
      region          = var.region
      instance_ids    = [aws_instance.instance.id]
    }
  }

  subscriber {
    address           = var.notification_email
    subscription_type = "EMAIL"
  }
}