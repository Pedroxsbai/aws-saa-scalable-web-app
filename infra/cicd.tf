# ---------------------------------------------------------------------------
# CI/CD — authentification GitHub Actions → AWS par OIDC, sans clé longue
# durée. Deux rôles distincts, séparés par niveau de privilège :
#
#   github_actions_plan  : lecture seule, assumable par les runs déclenchés
#                           sur une pull request (workflow "plan").
#   github_actions_apply : lecture + écriture, assumable UNIQUEMENT par les
#                           runs déclenchés par un push sur main (workflow
#                           "apply"). Aucune pull request ne peut l'assumer.
#
# Le provider OIDC lui-même n'est pas circulaire à créer via Terraform (à la
# différence du bucket de state) : appliqué une première fois manuellement
# ici, il permet ensuite à la CI de gérer tout le reste — y compris, en
# théorie, ce fichier lui-même.
# ---------------------------------------------------------------------------

# AWS n'autorise qu'UN SEUL provider OIDC par URL et par compte. Ce compte en
# héberge déjà un pour token.actions.githubusercontent.com, créé par un autre
# projet (vérifié : aws iam list-open-id-connect-providers). Le créer ici
# échouerait (EntityAlreadyExists) et, plus grave, le state de CE projet
# n'a pas vocation à posséder une ressource partagée avec d'autres projets —
# un `terraform destroy` ne doit jamais pouvoir l'emporter. On le référence
# donc en lecture seule plutôt que de le créer.
data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  # Nom du bucket de state et de la table de verrou — dérivés de la même
  # convention que backend.hcl.example, pas exposés en variable pour éviter
  # une deuxième source de vérité.
  tfstate_bucket_name = "tfstate-aws-saa-manara-${local.account_id}"
  tfstate_lock_table  = "tf-lock-aws-saa-manara"

  # ATTENTION : le "sub" réellement émis par GitHub n'est PAS
  # "repo:owner/repo:...". Il inclut les identifiants numériques immuables du
  # propriétaire et du dépôt, accolés au nom par un "@" :
  #   repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/main
  # Vérifié via CloudTrail sur un run réel (AssumeRoleWithWebIdentity,
  # champ userIdentity.principalId) après un premier échec de matching avec
  # le format "documenté" naïf. Le nom seul ne suffit donc pas : on matche
  # par wildcard sur la partie variable (l'ID), pas sur le nom en entier.
  github_owner = split("/", var.github_repository)[0]
  github_repo  = split("/", var.github_repository)[1]

  github_sub_pull_request = "repo:${local.github_owner}@*/${local.github_repo}@*:pull_request"
  github_sub_main_push    = "repo:${local.github_owner}@*/${local.github_repo}@*:ref:refs/heads/main"
}

# ===========================================================================
# Politique d'accès au backend — state S3 + verrou DynamoDB.
# Identique pour les deux rôles : lire/écrire le state est indissociable de
# tout plan ou apply, ce n'est pas un privilège à part.
# ===========================================================================

data "aws_iam_policy_document" "tfstate_access" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.tfstate_bucket_name}"]
  }

  statement {
    sid    = "ReadWriteState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["arn:aws:s3:::${local.tfstate_bucket_name}/infra/*"]
  }

  statement {
    sid    = "StateLock"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = ["arn:aws:dynamodb:*:${local.account_id}:table/${local.tfstate_lock_table}"]
  }
}

# ===========================================================================
# Politique de lecture — utilisée par les deux rôles (le plan lit tout ce
# que l'apply lit, avant de décider quoi écrire).
#
# Scoping par ressource quand l'ARN le permet (IAM, budgets, logs, SNS,
# CloudWatch) ; large mais en lecture seule pour les services dont l'API ne
# supporte pas de scoping fin sur les actions Describe/List (EC2, RDS, ELB,
# Auto Scaling) — une politique Describe* est en pratique peu risquée : elle
# ne permet ni modification ni exfiltration de secrets applicatifs.
# ===========================================================================

data "aws_iam_policy_document" "provisioning_read" {
  statement {
    sid    = "ReadOnlyDescribe"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "elasticloadbalancing:Describe*",
      "autoscaling:Describe*",
      "rds:Describe*",
      "rds:ListTagsForResource",
      "cloudfront:GetDistribution*",
      "cloudfront:ListDistributions",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:ListOriginAccessControls",
      "cloudfront:ListTagsForResource",
      "sns:GetTopicAttributes",
      "sns:ListTopics",
      "sns:ListSubscriptionsByTopic",
      "sns:ListTagsForResource",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:GetDashboard",
      "cloudwatch:ListDashboards",
      "cloudwatch:ListTagsForResource",
      "logs:DescribeLogGroups",
      "logs:ListTagsForResource",
      "budgets:ViewBudget",
      "budgets:DescribeBudgetAction*",
      "budgets:ListTagsForResource",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecrets",
      "ssm:DescribeParameters",
      "ssm:GetParameter*",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadOnlyIamScoped"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:GetInstanceProfile",
      "iam:GetOpenIDConnectProvider",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*",
      "arn:aws:iam::${local.account_id}:instance-profile/${local.name_prefix}-*",
      "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com",
    ]
  }

  # Les actions List* d'IAM (ListRoles, ListOpenIDConnectProviders...) ne
  # supportent PAS le scoping par ressource : elles énumèrent tout le
  # compte par construction, IAM exige donc Resource = "*". Découvert à
  # l'exécution réelle en CI (AccessDenied sur data.aws_iam_openid_connect_provider,
  # qui appelle ListOpenIDConnectProviders avant de filtrer par URL côté
  # client) — pas visible en local avec un rôle qui a déjà tous les droits.
  statement {
    sid    = "ReadOnlyIamListAccountWide"
    effect = "Allow"
    actions = [
      "iam:ListRoles",
      "iam:ListOpenIDConnectProviders",
    ]
    resources = ["*"]
  }

  # s3:Get* plutôt qu'une liste de noms d'actions individuels : la
  # ressource aws_s3_bucket lit en une passe versioning, chiffrement, ACL,
  # accélération, réplication, etc. — et la nomenclature IAM de ces actions
  # est incohérente (ex. "s3:GetAccelerateConfiguration", SANS "Bucket"
  # dans le nom, contrairement à "s3:GetBucketVersioning"). Une liste
  # explicite se fait contourner par la moindre action non anticipée ;
  # le wildcard reste scopé à nos seuls buckets.
  statement {
    sid    = "ReadOnlyS3Assets"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:Get*",
    ]
    resources = [
      "arn:aws:s3:::${local.name_prefix}-*",
      "arn:aws:s3:::${local.name_prefix}-*/*",
    ]
  }
}

# ===========================================================================
# Politique d'écriture — utilisée UNIQUEMENT par le rôle apply.
#
# Même logique de scoping que la politique de lecture : IAM restreint au
# préfixe du projet (c'est le service où une fuite de privilège serait la
# plus grave), Secrets Manager restreint aux secrets gérés par RDS
# (préfixe "rds!", imposé par AWS, pas par ce projet — c'est la meilleure
# restriction statique possible sans connaître l'ARN exact avant le premier
# apply). Le reste (EC2/RDS/ELB/ASG/CloudFront/SNS/CloudWatch/Budgets/Logs)
# n'a pas de mécanisme de scoping par nom ou tag utilisable de façon fiable
# à la fois pour la création ET la lecture ultérieure dans ce projet — assumé
# et documenté dans l'ADR-003, pas un oubli.
# ===========================================================================

data "aws_iam_policy_document" "provisioning_write" {
  statement {
    sid    = "ManageNetworkingComputeData"
    effect = "Allow"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "rds:*",
      "cloudfront:*",
      "sns:*",
      "cloudwatch:*",
      "logs:*",
      "budgets:*",
      "ssm:*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageIamScoped"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      # Action distincte de UpdateRole : c'est celle-ci qui modifie
      # spécifiquement le document de confiance (assume_role_policy), pas
      # les métadonnées du rôle. Manquante initialement — le rôle ne
      # pouvait donc pas se remettre lui-même à jour (ni mettre à jour son
      # rôle jumeau), révélé par un run réel appliquant sa propre CI.
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*",
      "arn:aws:iam::${local.account_id}:instance-profile/${local.name_prefix}-*",
    ]
  }

  statement {
    sid    = "ManageS3Assets"
    effect = "Allow"
    # Get* est déjà couvert par provisioning_read (attachée aux deux rôles) ;
    # ne pas le dupliquer ici. s3:Put* plutôt qu'une liste de noms
    # individuels, même raison que ReadOnlyS3Assets : la nomenclature IAM
    # de ces actions est incohérente d'une configuration de bucket à l'autre.
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:ListBucket",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:Put*",
    ]
    resources = [
      "arn:aws:s3:::${local.name_prefix}-*",
      "arn:aws:s3:::${local.name_prefix}-*/*",
    ]
  }

  statement {
    sid    = "ManageRdsManagedSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:PutResourcePolicy",
      "secretsmanager:TagResource",
    ]
    # Préfixe imposé par AWS pour tout secret créé via
    # manage_master_user_password — jamais un nom de secret applicatif.
    resources = ["arn:aws:secretsmanager:*:${local.account_id}:secret:rds!*"]
  }
}

# ===========================================================================
# Rôle "plan" — assumable uniquement par les runs de pull request.
# ===========================================================================

data "aws_iam_policy_document" "assume_plan" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_sub_pull_request]
    }
  }
}

resource "aws_iam_role" "github_actions_plan" {
  name               = "${local.name_prefix}-gha-plan"
  assume_role_policy = data.aws_iam_policy_document.assume_plan.json

  tags = {
    Name = "${local.name_prefix}-gha-plan"
  }
}

resource "aws_iam_role_policy" "plan_tfstate" {
  name   = "tfstate-access"
  role   = aws_iam_role.github_actions_plan.id
  policy = data.aws_iam_policy_document.tfstate_access.json
}

resource "aws_iam_role_policy" "plan_read" {
  name   = "provisioning-read"
  role   = aws_iam_role.github_actions_plan.id
  policy = data.aws_iam_policy_document.provisioning_read.json
}

# ===========================================================================
# Rôle "apply" — assumable uniquement par les runs déclenchés par un push
# sur main. Aucune pull request, même depuis ce dépôt, ne peut l'assumer.
# ===========================================================================

data "aws_iam_policy_document" "assume_apply" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_sub_main_push]
    }
  }
}

resource "aws_iam_role" "github_actions_apply" {
  name               = "${local.name_prefix}-gha-apply"
  assume_role_policy = data.aws_iam_policy_document.assume_apply.json

  tags = {
    Name = "${local.name_prefix}-gha-apply"
  }
}

resource "aws_iam_role_policy" "apply_tfstate" {
  name   = "tfstate-access"
  role   = aws_iam_role.github_actions_apply.id
  policy = data.aws_iam_policy_document.tfstate_access.json
}

resource "aws_iam_role_policy" "apply_read" {
  name   = "provisioning-read"
  role   = aws_iam_role.github_actions_apply.id
  policy = data.aws_iam_policy_document.provisioning_read.json
}

resource "aws_iam_role_policy" "apply_write" {
  name   = "provisioning-write"
  role   = aws_iam_role.github_actions_apply.id
  policy = data.aws_iam_policy_document.provisioning_write.json
}
