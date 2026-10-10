# ADR-0013: VPCは3環境で共有する。
# タスクはパブリックサブネットに置き、NAT Gateway / VPCエンドポイントは作らない。
# 本構成は本番想定ではない（README参照）。

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${count.index + 1}"
    Tier = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}-public"
  }
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# デフォルトセキュリティグループは全ルールを削除して使わせない
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-default-do-not-use"
  }
}

# ---------------------------------------------------------------------------
# ECSクラスターは環境ごとに作る（クラスター自体に課金はない）。
# 1アカウント内の環境分離を、クラスター境界としても表現しておく（ADR-0006）。
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  for_each = toset(var.environments)

  name = "${var.name_prefix}-${each.value}"

  setting {
    # コスト抑制のため実験では無効
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Environment = each.value
  }
}
