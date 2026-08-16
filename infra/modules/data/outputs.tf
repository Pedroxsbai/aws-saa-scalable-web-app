output "db_instance_id" {
  description = "Identifiant de l'instance RDS."
  value       = aws_db_instance.this.id
}

output "db_endpoint" {
  description = "Endpoint de connexion, host:port."
  value       = aws_db_instance.this.endpoint
}

output "db_address" {
  description = "Nom d'hôte de l'instance, sans le port."
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "Port d'écoute PostgreSQL."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Nom de la base applicative."
  value       = aws_db_instance.this.db_name
}

output "db_secret_arn" {
  description = "ARN du secret Secrets Manager portant les identifiants maître. À référencer depuis le rôle IAM d'instance pour l'accès en lecture."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
