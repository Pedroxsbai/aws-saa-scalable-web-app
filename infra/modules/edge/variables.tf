# ---------------------------------------------------------------------------
# Entrées du module edge.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Préfixe de nommage des ressources."
  type        = string
}

variable "enable_cloudfront" {
  description = "Déploie la distribution CloudFront devant le bucket. Si false, le bucket existe mais reste privé — aucune diffusion publique."
  type        = bool
  default     = false
}

variable "cloudfront_price_class" {
  description = "Classe de prix CloudFront."
  type        = string
  default     = "PriceClass_100"
}

variable "s3_force_destroy" {
  description = "Autorise la destruction du bucket même s'il contient des objets."
  type        = bool
  default     = true
}
