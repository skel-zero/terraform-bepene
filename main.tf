locals {
  replicas_sa_east_1 = { for r in var.replicas : r.subdomain => r if r.region == "sa-east-1" }
  replicas_us_east_1 = { for r in var.replicas : r.subdomain => r if r.region == "us-east-1" }
}

data "aws_iam_role" "budgets_role" {
  name = "BudgetsRole"
}

resource "aws_budgets_budget" "monthly_cost_budget" {
  name              = "BepeneMonthlyBudget"
  budget_type       = "COST"
  limit_amount      = "50.0"
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-31_21:00"

  filter_expression {
    not {
      dimensions {
        key    = "RECORD_TYPE"
        values = ["Credit", "Refund"]
      }
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.replicas[0].notification_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.replicas[0].notification_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 85
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.replicas[0].notification_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.replicas[0].notification_email]
  }
}

resource "aws_globalaccelerator_accelerator" "accelerator" {
  name            = "Bepene"
  ip_address_type = "IPV4"
  enabled         = true
  attributes {
    flow_logs_enabled = false
  }

}

module "bpn_sa_east_1" {

  for_each = local.replicas_sa_east_1

  source = "./modules/bpn"

  providers = {
    aws = aws.sa_east_1
  }

  zone_id   = each.value.zone_id
  domain    = each.value.domain
  subdomain = each.value.subdomain

  region = each.value.region

  instance_type = each.value.instance_type

  accelerator = {
    arn = aws_globalaccelerator_accelerator.accelerator.arn
    ips = aws_globalaccelerator_accelerator.accelerator.ip_sets
  }

  vpn_server_port = each.value.vpn_server_port

  public_key = each.value.public_key

  notification_email = each.value.notification_email

  budget_name      = aws_budgets_budget.monthly_cost_budget.name
  budgets_role_arn = data.aws_iam_role.budgets_role.arn

}

module "bpn_us_east_1" {

  for_each = local.replicas_us_east_1

  source = "./modules/bpn"

  providers = {
    aws = aws.us_east_1
  }

  zone_id   = each.value.zone_id
  domain    = each.value.domain
  subdomain = each.value.subdomain

  region = each.value.region

  instance_type = each.value.instance_type

  accelerator = {
    arn = aws_globalaccelerator_accelerator.accelerator.arn
    ips = aws_globalaccelerator_accelerator.accelerator.ip_sets
  }

  vpn_server_port = each.value.vpn_server_port

  public_key = each.value.public_key

  notification_email = each.value.notification_email

  budget_name      = aws_budgets_budget.monthly_cost_budget.name
  budgets_role_arn = data.aws_iam_role.budgets_role.arn

}