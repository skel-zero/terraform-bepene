# NEW: Print the Magic IPs to the terminal when finished
output "accelerator_ips" {
  description = "Your Anycast IPs for the WireGuard Windows Client"
  value       = aws_globalaccelerator_accelerator.accelerator.ip_sets
}

output "instance_public_ip" {
  description = "Use this IP to SSH into the server to retrieve your config"
  value       = aws_instance.instance.public_ip
}