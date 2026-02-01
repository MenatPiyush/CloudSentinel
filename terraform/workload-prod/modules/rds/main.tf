resource "aws_db_subnet_group" "this" {
  name = "${var.name}-db-subnet-group"
  subnet_ids = var.db_subnet_ids

  tags = {
    Name = "${var.name}-db-subnet-group"
  }
  
}

resource "aws_security_group" "db" {
  name = "${var.name}-db-sg"
  description = "Security group for RDS instance"
  vpc_id = var.vpc_id

  ingress {
    from_port = 5432
    to_port = 5432
    protocol = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "this" {
  identifier = "${var.name}-pg"
  engine = "postgres"
  engine_version = "15"
  instance_class = "db.t4g.medium"
  allocated_storage = 50

  db_subnet_group_name = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible = false
  multi_az = true
  storage_encrypted = true

  username = var.db_username
  password = var.db_password

  backup_retention_period = 7
  skip_final_snapshot = true
    
    tags = {
        Name = "${var.name}-db-instance"
    }
}