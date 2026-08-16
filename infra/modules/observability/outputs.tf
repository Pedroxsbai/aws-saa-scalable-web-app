output "sns_topic_arn" {
  description = "ARN du topic SNS d'alertes."
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "Nom du tableau de bord CloudWatch."
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "dashboard_url" {
  description = "URL directe du tableau de bord dans la console AWS."
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "budget_name" {
  description = "Nom du budget AWS Budgets."
  value       = aws_budgets_budget.monthly.name
}
