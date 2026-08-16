# ---------------------------------------------------------------------------
# Variables d'entrée du projet.
#
# À ce stade (session 1 — scaffolding), AUCUNE de ces variables n'est encore
# consommée par une ressource. Elles sont déclarées ici pour figer le contrat
# d'interface de la stack avant d'écrire les modules. `terraform validate`
# passe, `terraform plan` ne produit rien.
#
# Convention de nommage des ressources (appliquée dans les modules) :
#   "${var.project_name}-${var.environment}-<role>"
#   ex. aws-saa-manara-dev-alb, aws-saa-manara-dev-asg
# ---------------------------------------------------------------------------


# ===========================================================================
# Identité du projet
# ===========================================================================

variable "project_name" {
  description = "Préfixe de nommage de toutes les ressources et valeur du tag Project."
  type        = string
  default     = "aws-saa-manara"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,31}$", var.project_name))
    error_message = "project_name : minuscules, chiffres et tirets uniquement, 3 à 32 caractères, doit commencer par une lettre."
  }
}

variable "environment" {
  description = "Environnement logique. Une seule valeur exploitée dans ce projet (dev), la liste prépare une extension ultérieure."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment doit valoir dev, staging ou prod."
  }
}

variable "owner" {
  description = "Responsable de la stack, reporté en tag. Sert au suivi de coûts et à l'identification en cas d'orphelin."
  type        = string
  default     = "manara-graduation"
}

variable "extra_tags" {
  description = "Tags additionnels fusionnés avec les tags obligatoires du provider. Les tags obligatoires ne peuvent pas être écrasés ici."
  type        = map(string)
  default     = {}
}


# ===========================================================================
# Région et zones de disponibilité
# ===========================================================================

variable "region" {
  description = "Région AWS de déploiement."
  type        = string
  default     = "eu-west-3" # Paris — proximité et conformité RGPD

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "region doit être un identifiant de région AWS valide, ex. eu-west-3."
  }
}

variable "az_suffixes" {
  description = "Suffixes des AZ utilisées, concaténés à var.region. Deux AZ suffisent pour démontrer la haute disponibilité tout en restant dans le budget."
  type        = list(string)
  default     = ["a", "b"]

  validation {
    condition     = length(var.az_suffixes) >= 2 && length(var.az_suffixes) <= 3
    error_message = "az_suffixes doit contenir entre 2 et 3 entrées (2 = HA minimale exigée par l'ALB)."
  }
}


# ===========================================================================
# Réseau
# ===========================================================================

variable "vpc_cidr" {
  description = "Bloc CIDR du VPC. /16 laisse largement la place aux trois tiers de subnets sur 2 à 3 AZ."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr doit être un CIDR valide de taille /20 ou plus large."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR des subnets publics (ALB, NAT). Un par AZ, dans l'ordre de var.az_suffixes."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]

  validation {
    condition     = alltrue([for c in var.public_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "public_subnet_cidrs : tous les éléments doivent être des CIDR valides."
  }

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.az_suffixes)
    error_message = "public_subnet_cidrs doit contenir exactement un CIDR par AZ déclarée dans az_suffixes."
  }
}

variable "private_app_subnet_cidrs" {
  description = "CIDR des subnets privés applicatifs (instances EC2 de l'ASG). Un par AZ."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]

  validation {
    condition     = alltrue([for c in var.private_app_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "private_app_subnet_cidrs : tous les éléments doivent être des CIDR valides."
  }

  validation {
    condition     = length(var.private_app_subnet_cidrs) == length(var.az_suffixes)
    error_message = "private_app_subnet_cidrs doit contenir exactement un CIDR par AZ déclarée dans az_suffixes."
  }
}

variable "private_data_subnet_cidrs" {
  description = "CIDR des subnets privés données (RDS). Isolés, sans route vers Internet. Un par AZ."
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]

  validation {
    condition     = alltrue([for c in var.private_data_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "private_data_subnet_cidrs : tous les éléments doivent être des CIDR valides."
  }

  validation {
    condition     = length(var.private_data_subnet_cidrs) == length(var.az_suffixes)
    error_message = "private_data_subnet_cidrs doit contenir exactement un CIDR par AZ déclarée dans az_suffixes."
  }
}


# ===========================================================================
# Sortie Internet des subnets privés — cf. ADR-001
# ===========================================================================

variable "nat_mode" {
  description = <<-EOT
    Stratégie de sortie Internet pour les subnets privés applicatifs :
      - "gateway"   : NAT Gateway managée. Robuste, ~32 USD/mois + transfert.
      - "instance"  : instance EC2 faisant du NAT. ~3 USD/mois, SPOF, à gérer.
      - "endpoints" : aucun NAT, uniquement des VPC endpoints (S3, SSM, ECR,
                      CloudWatch Logs). Coût minimal si peu d'endpoints, mais
                      aucun accès Internet sortant généraliste (pas de yum
                      update depuis Internet, pas d'appel d'API tierce).
    Justification du choix et matrice de décision : docs/adr/001-nat-mode-variable.md
  EOT
  type        = string
  default     = "instance" # profil économique : ~3 USD/mois contre ~32 pour "gateway"

  validation {
    condition     = contains(["gateway", "instance", "endpoints"], var.nat_mode)
    error_message = "nat_mode doit valoir gateway, instance ou endpoints."
  }
}

variable "nat_high_availability" {
  description = "Si true, déploie un NAT par AZ au lieu d'un seul dans la première AZ. Coûteux : double la facture NAT. Laissé à false pour ce projet (SPOF assumé, cf. README « Trade-offs »)."
  type        = bool
  default     = false
}

variable "enable_ssm_endpoints" {
  description = "Crée les endpoints d'interface SSM même quand un NAT existe déjà. Sans effet si nat_mode = \"endpoints\" (ils sont alors indispensables). Coût : ~7,50 USD/mois par endpoint et par AZ, soit ~45 USD/mois sur 2 AZ — d'où le défaut à false."
  type        = bool
  default     = false
}

variable "nat_instance_type" {
  description = "Type d'instance utilisé quand nat_mode = \"instance\". t4g.micro (ARM), le plus petit type ARM éligible free tier disponible sur ce compte — t4g.nano est refusé par l'API sur les comptes \"Free Plan\" (InvalidParameterCombination: not eligible for Free Tier)."
  type        = string
  default     = "t4g.micro"
}


# ===========================================================================
# Couche applicative — ALB + Auto Scaling Group
# ===========================================================================

variable "instance_type" {
  description = "Type d'instance EC2 des membres de l'ASG. t3.micro est éligible au free tier."
  type        = string
  default     = "t3.micro"
}

variable "app_port" {
  description = "Port d'écoute de l'application ASP.NET Core sur l'instance. Cible du target group ALB."
  type        = number
  default     = 8080

  validation {
    condition     = var.app_port > 0 && var.app_port <= 65535
    error_message = "app_port doit être compris entre 1 et 65535."
  }
}

variable "asg_min_size" {
  description = "Nombre minimal d'instances dans l'ASG. À 1 en profil économique : pas de redondance inter-AZ, à relever à 2 pour la démonstration de HA."
  type        = number
  default     = 1

  validation {
    condition     = var.asg_min_size >= 1
    error_message = "asg_min_size doit valoir au moins 1."
  }
}

variable "asg_max_size" {
  description = "Nombre maximal d'instances dans l'ASG. Plafond de sécurité budgétaire autant que technique."
  type        = number
  default     = 4

  validation {
    condition     = var.asg_max_size >= var.asg_min_size
    error_message = "asg_max_size doit être supérieur ou égal à asg_min_size."
  }
}

variable "asg_desired_capacity" {
  description = "Capacité souhaitée au démarrage. Reprise en main par la politique de scaling ensuite."
  type        = number
  default     = 1

  validation {
    condition     = var.asg_desired_capacity >= var.asg_min_size && var.asg_desired_capacity <= var.asg_max_size
    error_message = "asg_desired_capacity doit être comprise entre asg_min_size et asg_max_size."
  }
}

variable "asg_target_cpu_utilization" {
  description = "Cible de la politique de scaling par suivi de cible (CPU moyen, en %)."
  type        = number
  default     = 60

  validation {
    condition     = var.asg_target_cpu_utilization > 0 && var.asg_target_cpu_utilization <= 100
    error_message = "asg_target_cpu_utilization doit être compris entre 1 et 100."
  }
}

variable "alb_ingress_cidrs" {
  description = "CIDR autorisés à joindre l'ALB en 80/443. Ouvert par défaut : l'application est publique, la protection est déléguée au WAF."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_waf" {
  description = "Attache un Web ACL WAFv2 à l'ALB (règles managées AWS). Coût : ~5 USD/mois + par million de requêtes. false par défaut (profil économique) ; à activer pour la démonstration de sécurité."
  type        = bool
  default     = false
}


# ===========================================================================
# Couche données — RDS PostgreSQL
# ===========================================================================

variable "db_instance_class" {
  description = "Classe d'instance RDS. db.t4g.micro est éligible au free tier et suffisant en dev."
  type        = string
  default     = "db.t4g.micro"

  validation {
    condition     = startswith(var.db_instance_class, "db.")
    error_message = "db_instance_class doit commencer par \"db.\", ex. db.t4g.micro."
  }
}

variable "db_engine_version" {
  description = "Version majeure/mineure de PostgreSQL. Épinglée pour éviter une mise à jour surprise au prochain apply. Vérifier les versions disponibles : aws rds describe-db-engine-versions --engine postgres --region <region>."
  type        = string
  default     = "16.9"
}

variable "multi_az" {
  description = "Déploiement RDS Multi-AZ (réplique de secours synchrone). Double le coût de la base. Laissé à false pour le budget, activable pour la démonstration de HA."
  type        = bool
  default     = false
}

variable "db_allocated_storage" {
  description = "Stockage initial de la base, en Go. 20 Go est le plancher free tier gp3."
  type        = number
  default     = 20

  validation {
    condition     = var.db_allocated_storage >= 20 && var.db_allocated_storage <= 100
    error_message = "db_allocated_storage doit être compris entre 20 et 100 Go (garde-fou budget)."
  }
}

variable "db_name" {
  description = "Nom de la base créée à l'initialisation de l'instance."
  type        = string
  default     = "appdb"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.db_name))
    error_message = "db_name doit commencer par une lettre et ne contenir que lettres, chiffres et underscores."
  }
}

variable "db_username" {
  description = "Utilisateur maître de l'instance RDS. Le mot de passe n'est PAS une variable : il est généré par AWS Secrets Manager via manage_master_user_password, donc jamais présent dans le state en clair."
  type        = string
  default     = "appadmin"

  validation {
    condition     = !contains(["admin", "postgres", "root", "rdsadmin"], lower(var.db_username))
    error_message = "db_username ne doit pas être un nom réservé (admin, postgres, root, rdsadmin)."
  }
}

variable "db_backup_retention_days" {
  description = "Rétention des sauvegardes automatiques, en jours. 0 les désactive — interdit ici pour garder une démonstration de PITR crédible."
  type        = number
  default     = 1

  validation {
    condition     = var.db_backup_retention_days >= 1 && var.db_backup_retention_days <= 35
    error_message = "db_backup_retention_days doit être compris entre 1 et 35."
  }
}

variable "db_deletion_protection" {
  description = "Protection contre la suppression de l'instance RDS. DOIT rester false : la contrainte projet impose qu'un unique `terraform destroy` détruise tout."
  type        = bool
  default     = false
}


# ===========================================================================
# Couche edge — S3 + CloudFront
# ===========================================================================

variable "enable_cloudfront" {
  description = "Déploie la distribution CloudFront devant le bucket des assets statiques. false par défaut (profil économique) : une distribution met ~15 min à se déployer et autant à détruire, ce qui ralentit chaque cycle apply/destroy. À activer pour la démonstration finale."
  type        = bool
  default     = false
}

variable "cloudfront_price_class" {
  description = "Classe de prix CloudFront. PriceClass_100 limite aux edges Amérique du Nord et Europe, le moins cher."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "cloudfront_price_class doit valoir PriceClass_100, PriceClass_200 ou PriceClass_All."
  }
}

variable "s3_force_destroy" {
  description = "Autorise la destruction du bucket d'assets même s'il contient des objets. true parce que le projet doit se détruire en une commande ; à ne jamais laisser ainsi en production."
  type        = bool
  default     = true
}


# ===========================================================================
# Observabilité et garde-fous de coût
# ===========================================================================

variable "alarm_email" {
  description = "Adresse abonnée au topic SNS (alarmes CloudWatch et alertes budget). Laisser vide désactive l'abonnement. L'abonnement SNS par e-mail exige une confirmation manuelle par clic dans le message reçu."
  type        = string
  default     = ""

  validation {
    condition     = var.alarm_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alarm_email))
    error_message = "alarm_email doit être une adresse e-mail valide ou une chaîne vide."
  }
}

variable "log_retention_days" {
  description = "Rétention des log groups CloudWatch. Volontairement courte : les logs sont le poste de coût le plus sournois d'un compte de démonstration."
  type        = number
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "log_retention_days doit être une valeur de rétention acceptée par CloudWatch Logs."
  }
}

variable "budget_limit_usd" {
  description = "Plafond mensuel AWS Budgets, en USD. Déclenche une alerte, PAS un arrêt des ressources : AWS Budgets ne coupe rien tout seul."
  type        = number
  default     = 25

  validation {
    condition     = var.budget_limit_usd > 0 && var.budget_limit_usd <= 200
    error_message = "budget_limit_usd doit être compris entre 1 et 200 (crédit total du compte)."
  }
}

variable "budget_alert_thresholds" {
  description = "Pourcentages du budget déclenchant une notification."
  type        = list(number)
  default     = [50, 80, 100]
}

variable "enable_flow_logs" {
  description = "Active les VPC Flow Logs vers CloudWatch. Précieux pour déboguer un routage privé qui ne passe pas, mais facturé à l'ingestion : à activer ponctuellement, pas en permanence."
  type        = bool
  default     = false
}

variable "enable_detailed_monitoring" {
  description = "Monitoring EC2 à 1 minute au lieu de 5. Améliore la réactivité du scaling mais sort du free tier CloudWatch."
  type        = bool
  default     = false
}
