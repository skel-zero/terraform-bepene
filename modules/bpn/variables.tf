variable "domain" {
  description = "The domain to use for the subdomain"
  type        = string
}

variable "subdomain" {
  description = "The subdomain to use"
  type        = string
}

variable "zone_id" {
  description = "The Route53 zone ID where the record will be created"
  type        = string
}

variable "accelerator" {
  type        = object({
    arn = string
    ips = list(object({
      ip_addresses = list(string)
      ip_family    = string
    }))
  })
  
}

variable "vpn_server_port" {
  description = "The port for the VPN server"
  type        = number
  default = 443
}

variable "public_key" {
  description = "The public key for SSH access"
  type        = string
}

variable "notification_email" {
  description = "Email address to receive billing notifications"
  type        = string
}

variable "region" {
  description = "AWS region to deploy the resources"
  type        = string
}

variable "budget_name" {
  description = "Name of the budget to attach the action to"
  type        = string
}

variable "budgets_role_arn" {
  description = "ARN of the IAM role for budget actions"
  type        = string
}
variable "instance_type" {
  description = "EC2 instance type to use for the VPN server"
  type        = string
  default     = "t3.nano"
  
}
