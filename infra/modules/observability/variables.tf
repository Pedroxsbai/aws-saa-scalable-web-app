# ---------------------------------------------------------------------------
# Entrées du module observability.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Préfixe de nommage des ressources."
  type        = string
}

variable "alarm_email" {
  description = "Adresse abonnée au topic SNS. Chaîne vide pour désactiver l'abonnement (le topic et les alarmes existent quand même, juste sans destinataire e-mail)."
  type        = string
  default     = ""
}

variable "asg_name" {
  description = "Nom de l'Auto Scaling Group à surveiller, fourni par le module compute."
  type        = string
}

variable "alb_arn_suffix" {
  description = "Suffixe d'ARN de l'ALB (dimension CloudWatch LoadBalancer), fourni par le module compute."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Suffixe d'ARN du target group (dimension CloudWatch TargetGroup), fourni par le module compute."
  type        = string
}

variable "db_instance_id" {
  description = "Identifiant de l'instance RDS à surveiller, fourni par le module data."
  type        = string
}

variable "budget_limit_usd" {
  description = "Plafond mensuel AWS Budgets, en USD."
  type        = number
}

variable "budget_alert_thresholds" {
  description = "Pourcentages du budget déclenchant une notification."
  type        = list(number)
}

variable "project_name" {
  description = "Nom du projet, utilisé pour filtrer AWS Budgets par tag afin de ne suivre que le coût de cette stack."
  type        = string
}
