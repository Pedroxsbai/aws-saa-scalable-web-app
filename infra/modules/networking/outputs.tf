# ---------------------------------------------------------------------------
# Sorties consommées par les modules compute, data, edge et observability.
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "Identifiant du VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Bloc CIDR du VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Subnets publics, dans l'ordre des AZ. Destinés à l'ALB."
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "Subnets privés applicatifs, dans l'ordre des AZ. Destinés à l'ASG."
  value       = aws_subnet.private_app[*].id
}

output "private_data_subnet_ids" {
  description = "Subnets privés données, dans l'ordre des AZ. Destinés au subnet group RDS."
  value       = aws_subnet.private_data[*].id
}

output "alb_security_group_id" {
  description = "Security group de l'ALB."
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "Security group des instances applicatives."
  value       = aws_security_group.app.id
}

output "db_security_group_id" {
  description = "Security group de l'instance RDS."
  value       = aws_security_group.db.id
}

output "nat_mode" {
  description = "Mode de sortie Internet effectivement appliqué."
  value       = var.nat_mode
}

output "nat_public_ips" {
  description = "IP publiques des NAT. Vide en mode endpoints. Utile pour autoriser la stack sur une allowlist tierce."
  value = (
    var.nat_mode == "gateway" ? aws_eip.nat[*].public_ip :
    var.nat_mode == "instance" ? aws_instance.nat[*].public_ip :
    []
  )
}

output "internet_gateway_id" {
  description = "Identifiant de l'Internet Gateway."
  value       = aws_internet_gateway.this.id
}

output "interface_endpoint_ids" {
  description = "Endpoints d'interface créés, par nom de service."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}
