# Module `compute`

ALB, Auto Scaling Group et WAF optionnel — la couche applicative exposée
publiquement.

## Ce qu'il fait

- **ALB** internet-facing dans les subnets publics, listener HTTP:80 unique
  (pas de nom de domaine → pas de certificat ACM → pas de HTTPS sur l'ALB,
  cf. README racine « Trade-offs »).
- **Target group** avec health check sur `/health`, attendant un `200`.
- **Rôle IAM d'instance** minimal : `AmazonSSMManagedInstanceCore` (accès
  Session Manager, pas de bastion) + lecture seule du secret RDS ciblé par
  ARN exact (`db_secret_arn`) + écriture sur son propre log group.
- **Launch template** IMDSv2 obligatoire, volume racine gp3 chiffré, AMI
  Amazon Linux 2023 résolue via le paramètre SSM public
  `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`
  (toujours à jour, pas d'AMI codée en dur à faire vieillir).
- **Auto Scaling Group** dans les subnets privés applicatifs, health check de
  type `ELB` (un processus planté mais un système qui répond doit être
  remplacé), politique de scaling par suivi de cible sur le CPU.
- **WAFv2** régional (`AWSManagedRulesCommonRuleSet` +
  `AWSManagedRulesKnownBadInputsRuleSet`), attaché à l'ALB uniquement si
  `enable_waf = true`.

## Placeholder applicatif — à remplacer

`app/` (session ultérieure) ne contient encore aucune application. Le
`user_data` du launch template installe donc un **stub** : un serveur HTTP
Python (préinstallé sur AL2023) qui répond `200 ok` sur toute route. Il
n'existe que pour valider l'ALB, le target group et l'ASG de bout en bout
sans dépendre du code applicatif.

**À remplacer** dès que l'application ASP.NET Core existe : récupération de
l'artefact publié (S3), service systemd `dotnet`, health check réel incluant
`/db-check`.

## Entrées principales

| Nom | Rôle |
|---|---|
| `public_subnet_ids` / `private_app_subnet_ids` | fournis par `networking` |
| `alb_security_group_id` / `app_security_group_id` | fournis par `networking` |
| `db_secret_arn` | fourni par `data`, portée du rôle IAM d'instance |
| `asg_min_size` / `asg_max_size` / `asg_desired_capacity` | dimensionnement, 1/4/1 par défaut (profil économique) |
| `enable_waf` | `false` par défaut — coût ~5 USD/mois + volumétrie |

## Sorties

`alb_dns_name`, `alb_zone_id`, `alb_arn`, `asg_name`, `app_role_arn`,
`waf_web_acl_arn` (`null` si `enable_waf = false`).

## Coût

`asg_min_size = 1`, `t3.micro` : ~7,50 USD/mois hors free tier (0 si
éligible). L'ALB lui-même coûte environ 18 USD/mois de socle, indépendamment
du nombre d'instances — c'est la ligne fixe la plus élevée après le NAT tant
que `enable_waf` et `enable_cloudfront` restent à `false`.
