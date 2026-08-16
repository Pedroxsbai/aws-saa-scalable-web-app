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
