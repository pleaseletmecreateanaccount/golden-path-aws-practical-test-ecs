# ==============================================================================
# Module: Networking
# Creates: VPC, 2 Public Subnets, 2 Private Subnets, IGW, NAT Gateway, Routes
#
# Cost notes:
#   - NAT Gateway: ~$0.045/hr + data charges. Not free-tier.
#     For dev/test with zero cost, set var.enable_nat_gateway = false
#     and tasks will need a VPC endpoint or public subnet placement.
#   - VPC itself: FREE
#   - Subnets, route tables, IGW: FREE
# ==============================================================================

# ------------------------------------------------------------------------------
# Variables
# ------------------------------------------------------------------------------

variable "name_prefix"          { type = string }
variable "vpc_cidr"             { type = string }
variable "public_subnet_cidrs"  { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "region"               { type = string }

variable "enable_nat_gateway" {
  description = "Set false to skip NAT Gateway and save cost in dev. Tasks must then be in public subnets or use VPC endpoints."
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# Data — fetch available AZs in the target region
# ------------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

# ------------------------------------------------------------------------------
# VPC
# ------------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true  # Required for Fargate service discovery & ECR pulls
  enable_dns_hostnames = true  # Required for VPC endpoints

  tags = { Name = "${var.name_prefix}-vpc" }
}

# ------------------------------------------------------------------------------
# Internet Gateway — used by public subnets (ALB egress)
# ------------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# ------------------------------------------------------------------------------
# Public Subnets — ALB lives here; one per AZ
# map_public_ip_on_launch=true so the ALB ENIs get public IPs automatically
# ------------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${count.index + 1}"
    Tier = "public"
    # Tag required by AWS Load Balancer Controller for subnet auto-discovery
    "kubernetes.io/role/elb" = "1"
  }
}

# ------------------------------------------------------------------------------
# Private Subnets — Fargate tasks run here; no direct internet access
# ------------------------------------------------------------------------------

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.name_prefix}-private-${count.index + 1}"
    Tier = "private"
    # Tag required by AWS Load Balancer Controller for internal ELB discovery
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ------------------------------------------------------------------------------
# NAT Gateway — allows private subnets to pull container images & call AWS APIs
# Placed in public-subnet-1 only (single NAT = cost trade-off for dev)
# For production: create one NAT GW per AZ for HA
# ------------------------------------------------------------------------------

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id # Attach to first public subnet

  tags = { Name = "${var.name_prefix}-nat-gw" }

  depends_on = [aws_internet_gateway.main]
}

# ------------------------------------------------------------------------------
# Route Tables
# ------------------------------------------------------------------------------

# Public: route all non-VPC traffic out through IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.name_prefix}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private: route all non-VPC traffic through NAT Gateway (if enabled)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.main[0].id
    }
  }

  tags = { Name = "${var.name_prefix}-rt-private" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ------------------------------------------------------------------------------
# VPC Endpoints — Fargate needs to reach ECR, S3, and CloudWatch Logs
# Using Interface endpoints removes NAT Gateway dependency for AWS API calls.
# Gateway endpoints (S3) are FREE; Interface endpoints have hourly cost.
#
# COST-SAVING OPTION: If enable_nat_gateway=false, these become mandatory.
#                     If enable_nat_gateway=true, they reduce data transfer cost.
# ------------------------------------------------------------------------------

# S3 Gateway Endpoint — FREE, reduces NAT data transfer for image pulls
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name_prefix}-vpce-s3" }
}

# ECR API Interface Endpoint — Fargate needs this to authenticate with ECR
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-vpce-ecr-api" }
}

# ECR Docker Interface Endpoint — Fargate needs this to pull image layers
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-vpce-ecr-dkr" }
}

# CloudWatch Logs Interface Endpoint — container logs go to CloudWatch
resource "aws_vpc_endpoint" "cloudwatch_logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-vpce-logs" }
}

# Secrets Manager Interface Endpoint — task fetches DB password at startup
resource "aws_vpc_endpoint" "secrets_manager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-vpce-secretsmanager" }
}

# Security group allowing HTTPS from within VPC to reach the endpoints
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name_prefix}-sg-vpce"
  description = "Allow HTTPS traffic from VPC to AWS service endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg-vpce" }
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "vpc_id"             { value = aws_vpc.main.id }
output "public_subnet_ids"  { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "vpc_cidr"           { value = var.vpc_cidr }
