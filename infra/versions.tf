# ---------------------------------------------------------------------------
# Contraintes de version — socle de reproductibilité du projet.
#
# Ce fichier ne déclare AUCUNE ressource : il fixe uniquement les versions de
# Terraform et des providers. Les versions exactes réellement utilisées sont
# figées dans .terraform.lock.hcl (commité), pour que le poste local et la CI
# GitHub Actions résolvent strictement les mêmes binaires.
# ---------------------------------------------------------------------------

terraform {
  # 1.9+ : requis pour les blocs `validation` avec accès cross-variable et les
  # améliorations d'`import`. Borne haute sur la série 1.x pour éviter qu'une
  # future 2.x introduise des ruptures silencieuses en CI.
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ~> 5.60 : autorise 5.60 -> 5.x (correctifs et nouvelles ressources),
      # bloque le passage automatique en 6.x qui contient des breaking changes.
      version = "~> 5.60"
    }

    # Génération de suffixes aléatoires (noms globalement uniques : bucket S3
    # des assets statiques, etc.). Utilisé à partir de la session « edge ».
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    # Empaquetage des sources Lambda / user-data en archive zip si nécessaire.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
