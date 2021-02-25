provider "aws" {
  region = var.region
}

resource "aws_vpc" "demo-vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}


resource "aws_subnet" "public-subnet-1" {
  cidr_block        = var.public_subnet_1_cidr
  vpc_id            = aws_vpc.demo-vpc.id
  availability_zone = var.availability_zones[0]
}
resource "aws_subnet" "public-subnet-2" {
  cidr_block        = var.public_subnet_2_cidr
  vpc_id            = aws_vpc.demo-vpc.id
  availability_zone = var.availability_zones[1]
}


resource "aws_subnet" "private-subnet-1" {
  cidr_block        = var.private_subnet_1_cidr
  vpc_id            = aws_vpc.demo-vpc.id
  availability_zone = var.availability_zones[0]
}

resource "aws_subnet" "private-subnet-2" {
  cidr_block        = var.private_subnet_2_cidr
  vpc_id            = aws_vpc.demo-vpc.id
  availability_zone = var.availability_zones[1]
}


resource "aws_route_table" "public-route-table" {
  vpc_id = aws_vpc.demo-vpc.id
}
resource "aws_route_table" "private-route-table" {
  vpc_id = aws_vpc.demo-vpc.id
}


resource "aws_route_table_association" "public-route-1-association" {
  route_table_id = aws_route_table.public-route-table.id
  subnet_id      = aws_subnet.public-subnet-1.id
}

resource "aws_route_table_association" "public-route-2-association" {
  route_table_id = aws_route_table.public-route-table.id
  subnet_id      = aws_subnet.public-subnet-2.id
}



resource "aws_eip" "elastic-ip-for-nat-gw" {
  vpc                       = true
  associate_with_private_ip = "10.0.0.5"
  depends_on                = [aws_internet_gateway.demo-igw]
}


resource "aws_nat_gateway" "nat-gw" {
  allocation_id = aws_eip.elastic-ip-for-nat-gw.id
  subnet_id     = aws_subnet.public-subnet-1.id
  depends_on    = [aws_eip.elastic-ip-for-nat-gw]
}
resource "aws_route" "nat-gw-route" {
  route_table_id         = aws_route_table.private-route-table.id
  nat_gateway_id         = aws_nat_gateway.nat-gw.id
  destination_cidr_block = "0.0.0.0/0"
}


resource "aws_internet_gateway" "demo-igw" {
  vpc_id = aws_vpc.demo-vpc.id
}

resource "aws_route" "public-internet-igw-route" {
  route_table_id         = aws_route_table.public-route-table.id
  gateway_id             = aws_internet_gateway.demo-igw.id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_security_group" "load-balancer" {
  name        = "load_balancer_security_group"
  description = "Controls access to the ALB"
  vpc_id      = aws_vpc.demo-vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2" {
  name        = "ecs_security_group"
  description = "Allows inbound access from the ALB only"
  vpc_id      = aws_vpc.demo-vpc.id

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.load-balancer.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}



resource "aws_lb" "demo" {
  name               = "demo-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.load-balancer.id]
  subnets            = [aws_subnet.public-subnet-1.id, aws_subnet.public-subnet-2.id]
}


resource "aws_alb_target_group" "default-target-group" {
  name     = "demo-client-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.demo-vpc.id

  health_check {
    path                = var.health_check_path_client
    port                = "traffic-port"
    healthy_threshold   = 5
    unhealthy_threshold = 2
    timeout             = 2
    interval            = 5
    matcher             = "200"
  }
}


resource "aws_alb_target_group" "users-target-group" {
  name     = "demo}-users-tg"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = aws_vpc.demo-vpc.id

  health_check {
    path                = var.health_check_path_users
    port                = "traffic-port"
    healthy_threshold   = 5
    unhealthy_threshold = 2
    timeout             = 2
    interval            = 5
    matcher             = "200"
  }
}


resource "aws_alb_listener" "demo-alb-http-listener" {
  load_balancer_arn = aws_lb.demo.id
  port              = "80"
  protocol          = "HTTP"
  depends_on        = [aws_alb_target_group.default-target-group]

  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.default-target-group.arn
  }
}

resource "aws_key_pair" "demo" {
  key_name   = "demo_key_pair"
  public_key = file(var.ssh_pubkey_file)
}

resource "aws_launch_configuration" "ecs" {
  name                        = "${var.ecs_cluster_name}-cluster"
  image_id                    = "ami-6871a115"
  instance_type               = var.instance_type
  security_groups             = [aws_security_group.ecs.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  key_name                    = aws_key_pair.demo.key_name
  associate_public_ip_address = true
  user_data                   = "#!/bin/bash\nyum install ansible\n"
  
   provisioner "local-exec" {
    command = <<EOF
aws --profile ec2_instance_profile ec2 wait instance-status-ok --region ${var.region}--instance-ids ${self.id} \
&& ansible-playbook  ansible/node.yaml
EOF
  }
}




resource "aws_autoscaling_group" "ecs-cluster" {
  name                 = "${var.ecs_cluster_name}_auto_scaling_group"
  min_size             = var.autoscale_min
  max_size             = var.autoscale_max
  desired_capacity     = var.autoscale_desired
  health_check_type    = "EC2"
  launch_configuration = aws_launch_configuration.ecs.name
  vpc_zone_identifier  = [aws_subnet.public-subnet-1.id, aws_subnet.public-subnet-2.id]
}
resource "aws_iam_role" "ec2-host-role" {
  name               = "ec2_host_role"
  assume_role_policy = file("policies/ec2-role.json")
}

resource "aws_iam_instance_profile" "ec2" {
  name = "ec2_instance_profile"
  path = "/"
  role = aws_iam_role.ec2-host-role.name
}
