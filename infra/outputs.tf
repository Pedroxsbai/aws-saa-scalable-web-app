# ---------------------------------------------------------------------------
# Sorties de la stack.
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "Identifiant du VPC."
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "Subnets publics (ALB, NAT)."
  value       = module.networking.public_subnet_ids
}

output "private_app_subnet_ids" {
  description = "Subnets privés applicatifs (ASG)."
  value       = module.networking.private_app_subnet_ids
}

output "private_data_subnet_ids" {
  description = "Subnets privés données (RDS)."
  value       = module.networking.private_data_subnet_ids
}

output "alb_dns_name" {
  description = "DNS public de l'ALB — point d'entrée de l'application, en HTTP (pas de nom de domaine, pas de HTTPS sur l'ALB)."
  value       = module.compute.alb_dns_name
}

output "asg_name" {
  description = "Nom de l'Auto Scaling Group."
  value       = module.compute.asg_name
}

output "db_endpoint" {
  description = "Endpoint de connexion RDS, host:port. Joignable uniquement depuis le SG applicatif."
  value       = module.data.db_endpoint
  sensitive   = true
}

output "db_secret_arn" {
  description = "ARN du secret Secrets Manager portant les identifiants RDS."
  value       = module.data.db_secret_arn
}

output "nat_mode" {
  description = "Mode de sortie Internet appliqué (cf. ADR-001)."
  value       = module.networking.nat_mode
}

output "nat_public_ips" {
  description = "IP publiques des NAT. Vide en mode endpoints."
  value       = module.networking.nat_public_ips
}

output "region" {
  description = "Région de déploiement."
  value       = var.region
}

output "availability_zones" {
  description = "AZ utilisées."
  value       = local.azs
}

output "name_prefix" {
  description = "Préfixe de nommage des ressources."
  value       = local.name_prefix
}

output "session_manager_hint" {
  description = "Rappel : aucun bastion, aucune clé SSH. La connexion aux instances passe par Session Manager."
  value       = "aws ssm start-session --target <instance-id> --region ${var.region}"
}
