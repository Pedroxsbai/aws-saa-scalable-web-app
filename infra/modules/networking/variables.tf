# ---------------------------------------------------------------------------
# Entrées du module networking.
#
# Le module ne connaît ni var.project_name ni var.environment : il reçoit un
# préfixe déjà construit. Il ne déclare pas non plus les tags obligatoires,
# hérités des default_tags du provider racine.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Préfixe de nommage des ressources, ex. aws-saa-manara-dev."
  type        = string
}

variable "vpc_cidr" {
  description = "Bloc CIDR du VPC."
  type        = string
}

variable "azs" {
  description = "Zones de disponibilité complètes, ex. [\"eu-west-3a\", \"eu-west-3b\"]. L'ordre fait foi : l'index 0 est l'AZ qui héberge le NAT unique."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR des subnets publics, un par AZ, dans l'ordre de var.azs."
  type        = list(string)
}

variable "private_app_subnet_cidrs" {
  description = "CIDR des subnets privés applicatifs, un par AZ."
  type        = list(string)
}

variable "private_data_subnet_cidrs" {
  description = "CIDR des subnets privés données, un par AZ."
  type        = list(string)
}

variable "nat_mode" {
  description = "Stratégie de sortie Internet : gateway, instance ou endpoints. Cf. docs/adr/001-nat-mode-variable.md."
  type        = string

  validation {
    condition     = contains(["gateway", "instance", "endpoints"], var.nat_mode)
    error_message = "nat_mode doit valoir gateway, instance ou endpoints."
  }
}

variable "nat_high_availability" {
  description = "true : un NAT par AZ. false : un seul NAT, dans var.azs[0], partagé par toutes les AZ."
  type        = bool
  default     = false
}

variable "nat_instance_type" {
  description = "Type d'instance quand nat_mode = \"instance\". Doit être une famille x86_64 pour rester cohérent avec l'AMI sélectionnée, et éligible free tier sur les comptes \"Free Plan\" (t3.nano est refusé par l'API sur ce type de compte, t3.micro passe)."
  type        = string
  default     = "t3.micro"
}

variable "enable_ssm_endpoints" {
  description = <<-EOT
    Crée les endpoints d'interface SSM même quand un NAT existe déjà.
    Sans effet en mode "endpoints", où ils sont créés de toute façon.

    COÛT : ~7,50 USD/mois PAR endpoint et PAR AZ, soit ~45 USD/mois pour les
    trois endpoints SSM sur 2 AZ. Laissé à false : avec un NAT, Session
    Manager fonctionne sans eux. Les activer maintient le trafic SSM à
    l'intérieur du réseau AWS — meilleure posture, coût réel.
  EOT
  type        = bool
  default     = false
}

variable "app_port" {
  description = "Port applicatif autorisé depuis l'ALB vers les instances."
  type        = number
  default     = 8080
}

variable "alb_ingress_cidrs" {
  description = "CIDR autorisés en 80/443 sur l'ALB."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "db_port" {
  description = "Port de la base de données, ouvert depuis le security group applicatif uniquement."
  type        = number
  default     = 5432
}

variable "enable_flow_logs" {
  description = "Active les VPC Flow Logs vers CloudWatch. Utile pour déboguer le routage privé, mais facturé à l'ingestion : à n'activer que ponctuellement."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "Rétention du log group des Flow Logs."
  type        = number
  default     = 7
}
