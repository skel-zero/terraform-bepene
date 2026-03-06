data "aws_route53_zone" "selected" {
  zone_id = var.zone_id
}

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = local.full_domain
  type    = "A"
  ttl     = 180
  records = [var.accelerator.ips[0].ip_addresses[0]]
}
