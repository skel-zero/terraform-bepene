output "accelerator_ips" {
  value       = aws_globalaccelerator_accelerator.accelerator.ip_sets
}

output "instance_public_ip" {
  value       = aws_instance.instance.public_ip
}