output "assets_bucket_name" {
  description = "Nom du bucket S3 des assets statiques."
  value       = aws_s3_bucket.assets.id
}

output "assets_bucket_arn" {
  description = "ARN du bucket S3 des assets statiques."
  value       = aws_s3_bucket.assets.arn
}

output "cloudfront_domain_name" {
  description = "Domaine public de la distribution CloudFront. Null si enable_cloudfront = false."
  value       = var.enable_cloudfront ? aws_cloudfront_distribution.assets[0].domain_name : null
}

output "cloudfront_distribution_id" {
  description = "Identifiant de la distribution CloudFront, utile pour une invalidation de cache. Null si enable_cloudfront = false."
  value       = var.enable_cloudfront ? aws_cloudfront_distribution.assets[0].id : null
}
