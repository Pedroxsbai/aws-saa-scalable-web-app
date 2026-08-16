# ---------------------------------------------------------------------------
# Entrées du module compute.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Préfixe de nommage des ressources."
  type        = string
}

variable "vpc_id" {
  description = "VPC cible."
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets publics pour l'ALB, un par AZ."
  type        = list(string)
}

variable "private_app_subnet_ids" {
  description = "Subnets privés applicatifs pour l'ASG, un par AZ."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group de l'ALB (alb-sg), créé par le module networking."
  type        = string
}

variable "app_security_group_id" {
  description = "Security group des instances applicatives (app-sg), créé par le module networking."
  type        = string
}

variable "app_port" {
  description = "Port d'écoute de l'application, cible du target group."
  type        = number
}

variable "instance_type" {
  description = "Type d'instance EC2 des membres de l'ASG."
  type        = string
}

variable "asg_min_size" {
  description = "Taille minimale de l'ASG."
  type        = number
}

variable "asg_max_size" {
  description = "Taille maximale de l'ASG."
  type        = number
}

variable "asg_desired_capacity" {
  description = "Capacité souhaitée au démarrage."
  type        = number
}

variable "asg_target_cpu_utilization" {
  description = "Cible CPU (%) de la politique de scaling par suivi de cible."
  type        = number
}

variable "db_secret_arn" {
  description = "ARN du secret Secrets Manager portant les identifiants RDS. Le rôle d'instance reçoit un accès en lecture seule à ce secret précis."
  type        = string
}

variable "enable_waf" {
  description = "Attache un Web ACL WAFv2 (règles managées AWS) à l'ALB."
  type        = bool
  default     = false
}

variable "enable_detailed_monitoring" {
  description = "Monitoring EC2 à la minute au lieu de 5 minutes."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Rétention du log group applicatif (stdout/stderr du service, remonté par l'agent CloudWatch)."
  type        = number
}
