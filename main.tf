resource "aws_globalaccelerator_accelerator" "accelerator" {
  name            = "Bepene"
  ip_address_type = "IPV4"
  enabled         = true
  attributes {
    flow_logs_enabled = false
  }

}


module "brazil" {
  source = "./modules/bpn"

  zone_id   = var.zone_id
  domain    = var.domain
  subdomain = var.subdomain

  accelerator = {
    arn = aws_globalaccelerator_accelerator.accelerator.arn
    ips = aws_globalaccelerator_accelerator.accelerator.ip_sets
  }

  public_key = var.public_key

  notification_email = var.notification_email

}