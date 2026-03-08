data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}
resource "aws_key_pair" "deployer" {
  key_name   = "saopaulo-ssh"
  public_key = var.public_key
}

resource "aws_security_group" "vpn_sg" {
  name        = "wireguard-bepene-sg"
  description = "Allow WireGuard and SSH"

  ingress {
    description = "WireGuard UDP"
    from_port   = var.vpn_server_port
    to_port     = var.vpn_server_port
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Strive UDP maybe"
    from_port   = 7777
    to_port     = 7777
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

/* not needed for now   
ingress {
    description = "SSH Access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  } */

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "instance" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.vpn_sg.id]

  user_data = templatefile("${path.root}/setup.tpl", {
    domain = local.full_domain
    port   = var.vpn_server_port
  })

  tags = {
    Name = "Bepene"
  }
}