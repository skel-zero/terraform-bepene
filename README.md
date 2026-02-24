ssh -i ~/Downloads/saopaulo ubuntu@$(terraform output -raw instance_public_ip)
ssh -i ~/Downloads/saopaulo ubuntu@$(terraform output -raw instance_public_ip) "cat /home/ubuntu/windows_client.conf"


# Server

wg genkey | tee server_private.key | wg pubkey > server_public.key

# Clients 

wg genkey | tee client_1_private.key | wg pubkey > client_1_public.key
wg genkey | tee client_2_private.key | wg pubkey > client_2_public.key
wg genkey | tee client_3_private.key | wg pubkey > client_3_public.key