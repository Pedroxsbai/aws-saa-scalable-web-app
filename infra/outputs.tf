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

output "artifact_bucket_name" {
  description = "Bucket S3 des artefacts de déploiement. Cible de `make deploy-app`."
  value       = module.compute.artifact_bucket_name
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

output "assets_bucket_name" {
  description = "Bucket S3 des assets statiques."
  value       = module.edge.assets_bucket_name
}

output "cloudfront_domain_name" {
  description = "Domaine public CloudFront. Null si enable_cloudfront = false."
  value       = module.edge.cloudfront_domain_name
}

output "github_actions_plan_role_arn" {
  description = "ARN du rôle IAM lecture seule assumé par la CI sur les pull requests."
  value       = aws_iam_role.github_actions_plan.arn
}

output "github_actions_apply_role_arn" {
  description = "ARN du rôle IAM lecture/écriture assumé par la CI sur les push vers main."
  value       = aws_iam_role.github_actions_apply.arn
}

output "sns_topic_arn" {
  description = "ARN du topic SNS d'alertes (alarmes CloudWatch et budget)."
  value       = module.observability.sns_topic_arn
}

output "dashboard_url" {
  description = "URL du tableau de bord CloudWatch."
  value       = module.observability.dashboard_url
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
