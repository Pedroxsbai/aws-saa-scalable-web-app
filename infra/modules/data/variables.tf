# ---------------------------------------------------------------------------
# Entrées du module data.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Préfixe de nommage des ressources."
  type        = string
}

variable "private_data_subnet_ids" {
  description = "Subnets privés données, un par AZ. Aucune route sortante attendue."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group RDS (db-sg), créé par le module networking. Autorise déjà le 5432 depuis app-sg."
  type        = string
}

variable "instance_class" {
  description = "Classe d'instance RDS."
  type        = string
}

variable "engine_version" {
  description = "Version PostgreSQL, épinglée."
  type        = string
}

variable "multi_az" {
  description = "Déploiement Multi-AZ. Double le coût de l'instance."
  type        = bool
}

variable "allocated_storage" {
  description = "Stockage initial, en Go."
  type        = number
}

variable "db_name" {
  description = "Nom de la base créée à l'initialisation."
  type        = string
}

variable "username" {
  description = "Utilisateur maître."
  type        = string
}

variable "backup_retention_days" {
  description = "Rétention des sauvegardes automatiques, en jours."
  type        = number
}

variable "deletion_protection" {
  description = "Protection contre la suppression. Doit rester false pour que `terraform destroy` réussisse en une commande."
  type        = bool
}

variable "log_retention_days" {
  description = "Rétention du log group des logs PostgreSQL exportés."
  type        = number
}

variable "sns_topic_arn" {
  description = "ARN du topic SNS pour les notifications d'événements RDS. Chaîne vide pour désactiver l'abonnement d'événements."
  type        = string
  default     = ""
}
