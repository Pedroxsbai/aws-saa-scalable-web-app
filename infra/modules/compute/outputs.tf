output "alb_dns_name" {
  description = "DNS public de l'ALB. Point d'entrée de l'application, en HTTP."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Zone ID de l'ALB — utile si un alias Route 53 est ajouté plus tard."
  value       = aws_lb.this.zone_id
}

output "alb_arn" {
  description = "ARN de l'ALB."
  value       = aws_lb.this.arn
}

output "alb_arn_suffix" {
  description = "Suffixe d'ARN de l'ALB (ex. app/name/id), requis comme dimension CloudWatch LoadBalancer par le module observability."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Suffixe d'ARN du target group, requis comme dimension CloudWatch TargetGroup par le module observability."
  value       = aws_lb_target_group.app.arn_suffix
}

output "asg_name" {
  description = "Nom de l'Auto Scaling Group."
  value       = aws_autoscaling_group.app.name
}

output "app_role_arn" {
  description = "ARN du rôle IAM des instances applicatives."
  value       = aws_iam_role.app.arn
}

output "artifact_bucket_name" {
  description = "Bucket S3 des artefacts de déploiement (dotnet publish). Cible de `make deploy-app`."
  value       = aws_s3_bucket.artifacts.id
}

output "waf_web_acl_arn" {
  description = "ARN du Web ACL WAFv2, vide si enable_waf = false."
  value       = var.enable_waf ? aws_wafv2_web_acl.alb[0].arn : null
}
