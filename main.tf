module "brazil" {
    source = "./modules/bpn"

    zone_id = var.zone_id   
    domain = var.domain
    subdomain = var.subdomain

    

    public_key = var.public_key

    notification_email = var.notification_email
    
}
