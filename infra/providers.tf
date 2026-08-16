# ---------------------------------------------------------------------------
# Providers et valeurs locales partagées.
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.region

  # Tags obligatoires appliqués automatiquement à toute ressource taggable
  # créée par ce provider. Les modules n'ont donc PAS à les répéter : ils ne
  # déclarent que les tags spécifiques (Name, Tier, ...).
  #
  # AutoDestroy=true signale explicitement qu'aucune ressource de cette stack
  # n'est destinée à survivre : elle sert de filtre pour les scripts de purge
  # et de garde-fou budgétaire.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      AutoDestroy = "true"
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}

# ---------------------------------------------------------------------------
# Provider secondaire épinglé sur us-east-1.
#
# Deux services l'imposent, quelle que soit la région de la stack :
#   - les certificats ACM consommés par CloudFront (non utilisés ici : pas de
#     nom de domaine, CloudFront servira son certificat *.cloudfront.net) ;
#   - les Web ACL WAFv2 de scope CLOUDFRONT.
#
# Conservé pour que l'ajout d'un domaine plus tard ne demande pas de
# refactoring du câblage des providers. Le WAF de l'ALB, lui, est de scope
# REGIONAL et utilise le provider par défaut.
# ---------------------------------------------------------------------------
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      AutoDestroy = "true"
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}

# ---------------------------------------------------------------------------
# Données de contexte du compte appelant.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# AZ réellement disponibles dans la région, filtrées sur les zones classiques
# (exclut les Local Zones et Wavelength, incompatibles avec RDS et l'ASG).
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# ---------------------------------------------------------------------------
# Valeurs locales.
# ---------------------------------------------------------------------------

locals {
  # Préfixe de nommage unique de toutes les ressources.
  # ex. aws-saa-manara-dev
  name_prefix = "${var.project_name}-${var.environment}"

  account_id = data.aws_caller_identity.current.account_id

  # AZ cibles, construites depuis la région et les suffixes demandés.
  # ex. ["eu-west-1a", "eu-west-1b"]
  azs = [for s in var.az_suffixes : "${var.region}${s}"]

  # Tags spécifiques venant s'ajouter aux default_tags du provider. Passer par
  # ce local plutôt que par var.extra_tags directement garantit qu'un tag
  # obligatoire ne peut pas être écrasé par erreur depuis un tfvars.
  common_tags = merge(
    var.extra_tags,
    {
      Project     = var.project_name
      Environment = var.environment
      AutoDestroy = "true"
      ManagedBy   = "terraform"
    }
  )

  # Nombre de NAT à créer selon la stratégie retenue (cf. ADR-001).
  #   endpoints                -> 0
  #   gateway/instance + HA    -> un par AZ
  #   gateway/instance sans HA -> un seul, dans la première AZ
  nat_count = (
    var.nat_mode == "endpoints" ? 0 :
    var.nat_high_availability ? length(local.azs) : 1
  )
}
