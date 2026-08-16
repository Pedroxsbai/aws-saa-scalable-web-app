# ---------------------------------------------------------------------------
# Module edge — bucket S3 des assets statiques, distribution CloudFront
# optionnelle en façade.
#
# Le bucket existe toujours (les assets doivent bien être stockés quelque
# part) ; seule la distribution CloudFront, coûteuse à faire tourner en
# itération (~15 min de déploiement/destruction), est optionnelle.
# ---------------------------------------------------------------------------

# Suffixe aléatoire : le nom d'un bucket S3 est unique à l'échelle mondiale,
# "${name_prefix}-assets" seul entrerait en collision avec d'autres comptes.
resource "random_id" "assets_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "assets" {
  bucket        = "${var.name_prefix}-assets-${random_id.assets_suffix.hex}"
  force_destroy = var.s3_force_destroy

  tags = {
    Name = "${var.name_prefix}-assets"
  }
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket = aws_s3_bucket.assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Ménage automatique des uploads multipart abandonnés — coût de stockage
# fantôme sinon, invisible tant qu'on ne va pas le chercher explicitement.
resource "aws_s3_bucket_lifecycle_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ===========================================================================
# CloudFront — optionnel
# ===========================================================================

resource "aws_cloudfront_origin_access_control" "assets" {
  count = var.enable_cloudfront ? 1 : 0

  name                              = "${var.name_prefix}-assets-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "assets" {
  count = var.enable_cloudfront ? 1 : 0

  enabled         = true
  is_ipv6_enabled = true
  price_class     = var.cloudfront_price_class
  comment         = "${var.name_prefix}-assets"

  origin {
    domain_name              = aws_s3_bucket.assets.bucket_regional_domain_name
    origin_id                = aws_s3_bucket.assets.id
    origin_access_control_id = aws_cloudfront_origin_access_control.assets[0].id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = aws_s3_bucket.assets.id
    viewer_protocol_policy = "redirect-to-https"

    # Politique managée AWS "CachingOptimized" — pas de cookies/query strings
    # en clé de cache, adaptée à des assets statiques versionnés.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Pas de nom de domaine : certificat par défaut *.cloudfront.net, pas d'ACM.
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "${var.name_prefix}-assets-cdn"
  }
}

# Seule la distribution CloudFront peut lire le bucket — jamais un accès
# public direct, jamais un accès anonyme via l'URL S3.
data "aws_iam_policy_document" "assets_cloudfront_only" {
  count = var.enable_cloudfront ? 1 : 0

  statement {
    sid    = "AllowCloudFrontServicePrincipalReadOnly"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.assets.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.assets[0].arn]
    }
  }
}

resource "aws_s3_bucket_policy" "assets_cloudfront_only" {
  count = var.enable_cloudfront ? 1 : 0

  bucket = aws_s3_bucket.assets.id
  policy = data.aws_iam_policy_document.assets_cloudfront_only[0].json
}
