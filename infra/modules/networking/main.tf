# ---------------------------------------------------------------------------
# Module networking — VPC, subnets, routage, sortie Internet, endpoints.
#
# Trois tiers de subnets, un par AZ :
#   public        : ALB, NAT — route par défaut vers l'Internet Gateway
#   private app   : instances de l'ASG — route par défaut selon nat_mode
#   private data  : RDS — AUCUNE route vers Internet, jamais
# ---------------------------------------------------------------------------

locals {
  # Nombre de NAT à créer (cf. ADR-001).
  nat_count = (
    var.nat_mode == "endpoints" ? 0 :
    var.nat_high_availability ? length(var.azs) : 1
  )

  # Index du NAT desservant l'AZ i. Sans HA, toutes les AZ pointent vers le
  # NAT unique de l'AZ 0 — c'est le SPOF assumé et documenté.
  nat_index_for_az = [for i in range(length(var.azs)) : var.nat_high_availability ? i : 0]

  # Les subnets privés applicatifs ont-ils une route par défaut ?
  has_default_route = var.nat_mode != "endpoints"

  # ATTENTION AU COÛT : un endpoint d'interface est facturé ~0,011 USD/heure
  # PAR ENI, donc par AZ — environ 7,50 USD/mois et par AZ. Sur 2 AZ, trois
  # endpoints SSM coûtent déjà ~45 USD/mois, soit plus qu'une NAT Gateway.
  #
  # Ils ne sont donc PAS créés systématiquement :
  #   - mode "endpoints" : indispensables, c'est la seule voie de sortie ;
  #   - modes "gateway" / "instance" : le trafic SSM emprunte le NAT, qui est
  #     déjà payé. On ne les crée que si enable_ssm_endpoints le demande
  #     explicitement (trafic SSM maintenu à l'intérieur du réseau AWS, ce qui
  #     est la posture de sécurité recommandée en production).
  ssm_endpoints = ["ssm", "ssmmessages", "ec2messages"]

  # En mode endpoints, aucune autre route sortante n'existe : tout service AWS
  # appelé par l'application doit avoir son propre endpoint.
  endpoints_mode_extras = [
    "logs",           # CloudWatch Logs — agent CloudWatch
    "monitoring",     # CloudWatch Metrics
    "secretsmanager", # mot de passe maître RDS
  ]

  interface_endpoints = (
    var.nat_mode == "endpoints" ? concat(local.ssm_endpoints, local.endpoints_mode_extras) :
    var.enable_ssm_endpoints ? local.ssm_endpoints :
    []
  )
}

# ===========================================================================
# VPC et Internet Gateway
# ===========================================================================

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Requis par les endpoints d'interface (résolution des noms privatelink) et
  # par le nommage DNS interne des instances.
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

# ===========================================================================
# Subnets
# ===========================================================================

resource "aws_subnet" "public" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  # L'ALB et le NAT ont besoin d'une IP publique. Les instances applicatives,
  # elles, ne sont jamais dans ce tier.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${var.azs[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "private_app" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_app_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.name_prefix}-private-app-${var.azs[count.index]}"
    Tier = "private-app"
  }
}

resource "aws_subnet" "private_data" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_data_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.name_prefix}-private-data-${var.azs[count.index]}"
    Tier = "private-data"
  }
}

# ===========================================================================
# Sortie Internet — mode "gateway"
# ===========================================================================

resource "aws_eip" "nat" {
  count = var.nat_mode == "gateway" ? local.nat_count : 0

  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = var.nat_mode == "gateway" ? local.nat_count : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.name_prefix}-nat-${var.azs[count.index]}"
  }

  depends_on = [aws_internet_gateway.this]
}

# ===========================================================================
# Sortie Internet — mode "instance"
#
# Une EC2 qui fait du masquerading. Beaucoup moins cher qu'une NAT Gateway
# (~3 USD/mois contre ~32), mais c'est un SPOF non managé : si l'instance
# tombe, les subnets privés perdent Internet jusqu'à intervention.
# ===========================================================================

data "aws_ami" "nat" {
  count = var.nat_mode == "instance" ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "nat_instance" {
  count = var.nat_mode == "instance" ? 1 : 0

  name        = "${var.name_prefix}-nat-instance-sg"
  description = "Trafic transitant par l'instance NAT"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-nat-instance-sg"
  }
}

# Tout le trafic venant des subnets privés applicatifs est routé et masqué.
resource "aws_vpc_security_group_ingress_rule" "nat_instance_from_private" {
  count = var.nat_mode == "instance" ? length(var.private_app_subnet_cidrs) : 0

  security_group_id = aws_security_group.nat_instance[0].id
  cidr_ipv4         = var.private_app_subnet_cidrs[count.index]
  ip_protocol       = "-1"
  description       = "Trafic sortant des instances applicatives de ${var.azs[count.index]}"
}

resource "aws_vpc_security_group_egress_rule" "nat_instance_all" {
  count = var.nat_mode == "instance" ? 1 : 0

  security_group_id = aws_security_group.nat_instance[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Sortie Internet"
}

resource "aws_instance" "nat" {
  count = var.nat_mode == "instance" ? local.nat_count : 0

  ami                    = data.aws_ami.nat[0].id
  instance_type          = var.nat_instance_type
  subnet_id              = aws_subnet.public[count.index].id
  vpc_security_group_ids = [aws_security_group.nat_instance[0].id]

  # Sans cela, le VPC jette les paquets dont l'instance n'est ni la source ni
  # la destination — c'est-à-dire tout le trafic qu'elle est censée router.
  source_dest_check = false

  # Accès administrateur par Session Manager, pas de key pair.
  iam_instance_profile = aws_iam_instance_profile.nat[0].name

  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    # Activation du routage IPv4
    echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-nat.conf
    sysctl -p /etc/sysctl.d/99-nat.conf

    # Masquerading sur l'interface portant la route par défaut
    dnf install -y iptables-services
    IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    iptables -F FORWARD

    # Persistance au redémarrage
    service iptables save
    systemctl enable --now iptables
  EOT

  # Force le remplacement de l'instance si le script change.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required" # IMDSv2 obligatoire
    http_endpoint = "enabled"
  }

  tags = {
    Name = "${var.name_prefix}-nat-instance-${var.azs[count.index]}"
  }
}

# Rôle minimal permettant l'accès Session Manager à l'instance NAT.
resource "aws_iam_role" "nat" {
  count = var.nat_mode == "instance" ? 1 : 0

  name = "${var.name_prefix}-nat-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  count = var.nat_mode == "instance" ? 1 : 0

  role       = aws_iam_role.nat[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  count = var.nat_mode == "instance" ? 1 : 0

  name = "${var.name_prefix}-nat-instance-profile"
  role = aws_iam_role.nat[0].name
}

# ===========================================================================
# Tables de routage
# ===========================================================================

# --- Public : une seule table, partagée par les deux AZ ---------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-public"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = length(var.azs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Privé applicatif : une table PAR AZ ------------------------------------
# Indispensable même sans HA : chaque AZ doit pouvoir pointer vers un NAT
# différent le jour où nat_high_availability passe à true.

resource "aws_route_table" "private_app" {
  count = length(var.azs)

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-private-app-${var.azs[count.index]}"
  }
}

resource "aws_route" "private_app_nat_gateway" {
  count = var.nat_mode == "gateway" ? length(var.azs) : 0

  route_table_id         = aws_route_table.private_app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[local.nat_index_for_az[count.index]].id
}

resource "aws_route" "private_app_nat_instance" {
  count = var.nat_mode == "instance" ? length(var.azs) : 0

  route_table_id         = aws_route_table.private_app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[local.nat_index_for_az[count.index]].primary_network_interface_id
}

resource "aws_route_table_association" "private_app" {
  count = length(var.azs)

  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[count.index].id
}

# --- Privé données : une table, aucune route sortante -----------------------
# Seule la route locale du VPC existe. RDS n'a rien à faire sur Internet.

resource "aws_route_table" "private_data" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-private-data"
  }
}

resource "aws_route_table_association" "private_data" {
  count = length(var.azs)

  subnet_id      = aws_subnet.private_data[count.index].id
  route_table_id = aws_route_table.private_data.id
}

# ===========================================================================
# VPC endpoints
# ===========================================================================

# --- S3, type gateway : GRATUIT, aucune raison de s'en priver ---------------
# Le trafic S3 (artefacts de déploiement, assets) ne consomme donc pas le NAT.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    aws_route_table.private_app[*].id,
    [aws_route_table.private_data.id],
  )

  tags = {
    Name = "${var.name_prefix}-vpce-s3"
  }
}

# --- Endpoints d'interface --------------------------------------------------
# ~7 USD/mois chacun, PAR AZ. C'est le poste qui rend le mode "endpoints"
# moins économique qu'il n'y paraît.

resource "aws_security_group" "vpc_endpoints" {
  count = length(local.interface_endpoints) > 0 ? 1 : 0

  name        = "${var.name_prefix}-vpce-sg"
  description = "HTTPS entrant vers les endpoints d'interface"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-vpce-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpce_https_from_vpc" {
  count = length(local.interface_endpoints) > 0 ? 1 : 0

  security_group_id = aws_security_group.vpc_endpoints[0].id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS depuis l'ensemble du VPC"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoints)

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = aws_subnet.private_app[*].id
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  # Permet d'appeler l'API par son nom public depuis le VPC, sans réécriture
  # d'URL côté application.
  private_dns_enabled = true

  tags = {
    Name = "${var.name_prefix}-vpce-${each.value}"
  }
}

# ===========================================================================
# Security groups applicatifs
#
# Regroupés ici parce qu'ils décrivent la topologie des flux entre tiers, pas
# le comportement des ressources qu'ils protègent. Les modules compute et data
# les consomment par leur id.
# ===========================================================================

# --- ALB : ouvert au public en 80/443 --------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Trafic public entrant vers l'ALB"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  count = length(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = var.alb_ingress_cidrs[count.index]
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP public"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count = length(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = var.alb_ingress_cidrs[count.index]
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS public (sans domaine, non exploite pour l'instant)"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
  description                  = "Vers les instances applicatives"
}

# --- Application : joignable UNIQUEMENT depuis l'ALB ------------------------

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "Instances applicatives de l'ASG"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-app-sg"
  }
}

# Référence par security group, pas par CIDR : les instances sont éphémères,
# leurs IP changent à chaque remplacement par l'ASG.
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
  description                  = "Trafic applicatif depuis l'ALB"
}

# Aucune règle SSH : l'accès se fait par Session Manager, qui sort en HTTPS
# vers les endpoints SSM. Le port 22 reste fermé, y compris depuis le VPC.
resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Sortie via NAT ou endpoints selon nat_mode"
}

# --- Base de données : 5432 depuis le SG applicatif seulement ---------------

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db-sg"
  description = "Instance RDS PostgreSQL"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-db-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL depuis les instances applicatives"
}

# Pas de règle d'egress sur le SG de la base : RDS n'initie aucune connexion
# sortante. Un SG sans règle d'egress bloque tout, ce qui est le comportement
# voulu ici.

# ===========================================================================
# VPC Flow Logs — désactivés par défaut
# ===========================================================================

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name_prefix}"
  retention_in_days = var.flow_logs_retention_days
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.name_prefix}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.name_prefix}-flow-logs-policy"
  role = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs[0].arn
  log_destination = aws_cloudwatch_log_group.flow_logs[0].arn

  tags = {
    Name = "${var.name_prefix}-flow-logs"
  }
}

data "aws_region" "current" {}
