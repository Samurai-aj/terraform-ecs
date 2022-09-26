resource "aws_vpc" "database-vpc" {

  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true


}

resource "aws_internet_gateway" "database-gw" {

  vpc_id = aws_vpc.database-vpc.id

}

resource "aws_route_table" "database-routetable" {

  vpc_id = aws_vpc.database-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.database-gw.id
  }

}

resource "aws_subnet" "database-subnet-private-us-west-1a" {

  vpc_id            = aws_vpc.database-vpc.id
  availability_zone = "us-west-1a"
  cidr_block        = "10.0.144.0/20"
}

resource "aws_subnet" "database-subnet-public-us-west-1a" {

  vpc_id                  = aws_vpc.database-vpc.id
  availability_zone       = "us-west-1a"
  cidr_block              = "10.0.128.0/20"
  map_public_ip_on_launch = true

}


resource "aws_subnet" "database-subnet-private-us-west-1c" {

  vpc_id            = aws_vpc.database-vpc.id
  availability_zone = "us-west-1c"
  cidr_block        = "10.0.0.0/20"

}



resource "aws_route_table_association" "db-assos" {

  subnet_id      = aws_subnet.database-subnet-public-us-west-1a.id
  route_table_id = aws_route_table.database-routetable.id

}



resource "aws_security_group" "ecs-security-group" {
  name        = "ecs-securitygroup"
  description = "security group ecs capacity provider instance"
  vpc_id      = aws_vpc.database-vpc.id

  ingress {
    description = "allow in connections from lb on port 80"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    description = "allow in connections for metabase on port 3000"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }


  egress {
    description = "allow all traffic go out"
    from_port   = "0"
    to_port     = "0"
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_security_group" "load-balancer-sg" {


  name        = "load-balancer-securitygroup"
  vpc_id      = aws_vpc.database-vpc.id
  description = "security group for load balancer"


  ingress {
    description = "allow in connections from everywhere to load balancer"
    from_port   = "80"
    to_port     = "80"
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "allow all traffic go out"
    from_port   = "0"
    to_port     = "0"
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_security_group" "database-security-group" {

  name        = "database-security-group"
  description = "allow traffic from vpc cidr block to rds instance"
  vpc_id      = aws_vpc.database-vpc.id

  ingress {
    description = "allow mysql/aurora connection on port 3306"
    from_port   = "3306"
    to_port     = "3306"
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }



  egress {
    description = "allow all traffic go out"
    from_port   = "0"
    to_port     = "0"
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/16"]
  }
}


#collect secret created in console to pass to rds instance
data "aws_secretsmanager_secret" "database-secret" {

  arn = "arn:aws:secretsmanager:us-west-1:950053190816:secret:database-admin-password-JWEGQ2"

}

data "aws_secretsmanager_secret_version" "password" {
  secret_id = "database-admin-password"

}

#use json to parse the secret
locals {
  db-final-secret = jsondecode(
    data.aws_secretsmanager_secret_version.password.secret_string
  )
}

#create subnet group where databses can be launced
resource "aws_db_subnet_group" "database-subnet-group" {

  name       = "ecomm-subnets"
  subnet_ids = [aws_subnet.database-subnet-private-us-west-1a.id, aws_subnet.database-subnet-private-us-west-1c.id]

  tags = {
    Name = "My Db subnet group"

  }

}

#create rds mariadb instance
resource "aws_db_instance" "maria-db" {

  allocated_storage = 20
  engine            = "mariadb"
  engine_version    = "10.6.8"
  instance_class    = "db.t3.micro"
  db_name           = "ecomdb"
  username          = local.db-final-secret.name
  password          = local.db-final-secret.password
  #password = "Blackship01"
  availability_zone      = "us-west-1a"
  db_subnet_group_name   = aws_db_subnet_group.database-subnet-group.name
  skip_final_snapshot    = true
  publicly_accessible    = true
  storage_type           = "gp2"
  vpc_security_group_ids = [aws_security_group.database-security-group.id]
  port                   = 3306
}


#ecsinstance role for launch template ec2 instances
data "aws_iam_instance_profile" "ecs-instance-profile" {
  name = "ecsInstanceRole"

}

data "aws_ami" "ecs-ami" {
  most_recent = true
  owners      = ["amazon"]


  filter {
    name   = "image-id"
    values = ["ami-0f987281f7836b330"]
  }
}


resource "aws_key_pair" "ecs-key-pair" {

  key_name   = "kodekloud-key"
  public_key = file("${path.module}/ec2.pub")

}



#loadbalancer for use with fargate
resource "aws_lb" "ecs-lb" {

  name               = "ecs-loadbalancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load-balancer-sg.id]
  subnets            = [aws_subnet.database-subnet-public-us-west-1a.id, aws_subnet.database-subnet-private-us-west-1c.id]

}

resource "aws_lb_target_group" "ecs-targetgroup" {
  name        = "ecs-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.database-vpc.id
  target_type = "ip"
}

resource "aws_lb_target_group" "metabase-targetgroup" {
  name        = "metabase-target-group"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.database-vpc.id
  target_type = "ip"

}


resource "aws_lb_listener" "ecs-lb-listener" {

  load_balancer_arn = aws_lb.ecs-lb.arn
  port              = 80
  protocol          = "HTTP"


  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs-targetgroup.arn
  }

}


resource "aws_lb_listener_rule" "static" {
  listener_arn = aws_lb_listener.ecs-lb-listener.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.metabase-targetgroup.arn
  }

  condition {
    path_pattern {
      values = ["/meta"]
    }
  }

}


#create an ecs cluster
resource "aws_ecs_cluster" "ecs-cluster" {
  name = "ecs-cluster"
}

#assign a capacity provider to the cluster
resource "aws_ecs_cluster_capacity_providers" "ecs-cap1" {

  cluster_name = aws_ecs_cluster.ecs-cluster.name

  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"

  }

}


#task definition file specifying the container details
resource "aws_ecs_task_definition" "php" {
  family                   = "php"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 1024
  container_definitions    = file("${path.module}/phpcontainerdefinition.json")
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

#similar to deployments in k8s, set up desired number of tasks to always run
resource "aws_ecs_service" "php" {
  name                               = "php"
  cluster                            = aws_ecs_cluster.ecs-cluster.id
  task_definition                    = aws_ecs_task_definition.php.id
  desired_count                      = 2
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 50
  health_check_grace_period_seconds  = 500


  load_balancer {
    target_group_arn = aws_lb_target_group.ecs-targetgroup.arn
    container_name   = "php-myadmin"
    container_port   = 80
  }

  network_configuration {

    subnets          = [aws_subnet.database-subnet-public-us-west-1a.id]
    security_groups  = [aws_security_group.ecs-security-group.id]
    assign_public_ip = true
  }

}



resource "aws_ecs_task_definition" "metabase" {
  family                   = "metabase"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  container_definitions    = file("${path.module}/metabase-containerdefinition.json")
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {

    name = "metabase-volume"

    efs_volume_configuration {

      file_system_id     = aws_efs_file_system.metabase-efs.id
      root_directory     = "/"
      transit_encryption = "DISABLED"

    }

  }


}

resource "aws_ecs_service" "metabase" {
  name                               = "metabase"
  cluster                            = aws_ecs_cluster.ecs-cluster.id
  task_definition                    = aws_ecs_task_definition.metabase.id
  desired_count                      = 1
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0
  #health_check_grace_period_seconds = 500


  load_balancer {
    target_group_arn = aws_lb_target_group.metabase-targetgroup.arn
    container_name   = "metabase"
    container_port   = 3000
  }

  network_configuration {

    subnets          = [aws_subnet.database-subnet-public-us-west-1a.id]
    security_groups  = [aws_security_group.ecs-security-group.id]
    assign_public_ip = true
  }

}


#efs volume to mount on metabase container
#first create security group to allow access to efs 
resource "aws_security_group" "efs-sg" {
  name        = "efs-securitygroup"
  description = "security group to allow connection to efs "
  vpc_id      = aws_vpc.database-vpc.id

  ingress {
    description = "allow in connections to nfs from port 2049"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    description = "allow all traffic go out"
    from_port   = "0"
    to_port     = "0"
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}


resource "aws_efs_file_system" "metabase-efs" {
  creation_token         = "metabase-efs"
  availability_zone_name = "us-west-1a"
  encrypted              = true
  throughput_mode        = "bursting"

}

resource "aws_efs_mount_target" "efs-mount" {
  file_system_id  = aws_efs_file_system.metabase-efs.id
  subnet_id       = aws_subnet.database-subnet-public-us-west-1a.id
  security_groups = [aws_security_group.efs-sg.id]

}





