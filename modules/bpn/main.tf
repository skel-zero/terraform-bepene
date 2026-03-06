resource "aws_globalaccelerator_listener" "listener" {
  accelerator_arn = var.accelerator.arn
  protocol        = "UDP"

  port_range {
    from_port = var.vpn_server_port
    to_port   = var.vpn_server_port
  }
}

resource "aws_globalaccelerator_endpoint_group" "endpoint_group" {
  listener_arn = aws_globalaccelerator_listener.listener.arn
  endpoint_group_region = "sa-east-1"

  endpoint_configuration {
    endpoint_id = aws_instance.instance.id
    weight      = 255
    client_ip_preservation_enabled = true
  }
}

