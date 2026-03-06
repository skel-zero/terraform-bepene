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