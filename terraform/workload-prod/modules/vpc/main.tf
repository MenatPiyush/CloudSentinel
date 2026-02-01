data "aws_region" "current" {}

resource "aws_vpc" "this" {
    cidr_block = var.cidr
    enable_dns_hostnames = true
    enable_dns_support   = true
    tags = {
        Name = var.name
    }
}

resource "aws_internet_gateway" "igw" {
    vpc_id = aws_vpc.this.id
    tags = {
        Name = "${var.name}-igw"
    }
}

locals {
    public_subnet_cidrs = [cidrsubnet(var.cidr, 4, 0), cidrsubnet(var.cidr, 4, 1)]
    private_subnet_cidrs = [cidrsubnet(var.cidr, 4, 2), cidrsubnet(var.cidr, 4, 3)]
    db_subnet_cidrs = [cidrsubnet(var.cidr, 4, 4), cidrsubnet(var.cidr, 4, 5)]
}

resource "aws_subnet" "public" {
    for_each = toset(var.azs)
    vpc_id = aws_vpc.this.id 
    cidr_block = local.public_subnet_cidrs[index(var.azs, each.value)]
    availability_zone = each.value
    map_public_ip_on_launch = true
    tags = {
        Name = "${var.name}-public-${each.value}","kubernetes.io/role/elb" = "1"
    }
}

resource "aws_subnet" "private" {
    for_each = toset(var.azs)
    vpc_id = aws_vpc.this.id 
    cidr_block = local.private_subnet_cidrs[index(var.azs, each.value)]
    availability_zone = each.value
    tags = {
        Name = "${var.name}-private-${each.value}","kubernetes.io/role/internal-elb" = "1"
    }
}

resource "aws_subnet" "db" {
    for_each = toset(var.azs)
    vpc_id = aws_vpc.this.id 
    cidr_block = local.db_subnet_cidrs[index(var.azs, each.value)]
    availability_zone = each.value
    tags = {
        Name = "${var.name}-db-${each.value}"
    }
}

resource "aws_eip" "nat" {
   for_each = aws_subnet.public
   domain = "vpc"
   tags = {
    Name = "${var.name}-nat-${each.key}"
   }
}

resource "aws_nat_gateway" "nat" {
   for_each = aws_subnet.public
   allocation_id = aws_eip.nat[each.key].id
   subnet_id = aws_subnet.public[each.key].id
   depends_on = [ aws_internet_gateway.igw ]
   tags = {
    Name = "${var.name}-nat-${each.key}"
   }
}

resource "aws_route_table" "public" {
    vpc_id = aws_vpc.this.id
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.igw.id
    }
    tags = {
        Name = "${var.name}-public-rt"
    }
}

resource "aws_route_table_association" "public" {
    for_each = aws_subnet.public
    subnet_id = each.value.id
    route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
    for_each = aws_subnet.private
    vpc_id = aws_vpc.this.id
    route {
        cidr_block = "0.0.0.0/0"
        nat_gateway_id = aws_nat_gateway.nat[each.key].id
    }
    tags = {
        Name = "${var.name}-private-rt"
    }
}

resource "aws_route_table_association" "private" {
    for_each = aws_subnet.private
    subnet_id = each.value.id
    route_table_id = aws_route_table.private[each.key].id
}