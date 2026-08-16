# Modules Terraform

Ce répertoire est vide à dessein en fin de session 1. Il accueillera cinq
modules locaux, écrits au fil des sessions suivantes. Aucun module externe
(registry public) n'est prévu : l'objectif pédagogique est d'écrire les
ressources à la main pour la préparation de la certification.

## Conventions communes

Chaque module suit la même structure de fichiers :

```
modules/<nom>/
├── main.tf       # ressources
├── variables.tf  # entrées, toutes documentées et validées
├── outputs.tf    # sorties consommées par la racine ou les autres modules
└── README.md     # rôle, entrées/sorties, coût, généré par `make docs`
```

Règles :

- Aucun module ne déclare de `provider` : ils héritent de la racine. Les
  modules ayant besoin de `us-east-1` reçoivent un alias via `providers = {}`.
- Aucun module ne re-déclare les tags obligatoires : ils viennent des
  `default_tags` du provider. Les modules n'ajoutent que `Name` et `Tier`.
- Le préfixe de nommage `local.name_prefix` est passé en entrée
  (`name_prefix`), jamais reconstruit dans le module.
- Toute ressource facturée à l'heure est pilotable par un `count`/`for_each`
  branché sur une variable d'activation, pour que le coût reste maîtrisable.

## Modules prévus

### `networking` — session 2

Le socle réseau. Tout le reste en dépend.

- VPC, Internet Gateway
- 6 subnets : 2 publics, 2 privés applicatifs, 2 privés données
- Tables de routage et associations
- Implémentation des trois branches de `nat_mode` : NAT Gateway, instance NAT,
  ou VPC endpoints seuls (cf. `docs/adr/001-nat-mode-variable.md`)
- VPC endpoints SSM / SSMMessages / EC2Messages — requis par Session Manager
  puisqu'il n'y a pas de bastion
- Security groups de base et NACL

Sorties : `vpc_id`, `public_subnet_ids`, `private_app_subnet_ids`,
`private_data_subnet_ids`.

### `compute` — session 3

La couche applicative exposée.

- Application Load Balancer, listener, target group, health checks
- Launch template (Amazon Linux 2023, user-data installant le runtime .NET)
- Auto Scaling Group réparti sur les AZ privées applicatives
- Politique de scaling par suivi de cible sur le CPU
- Rôle IAM d'instance + instance profile (`AmazonSSMManagedInstanceCore`)
- Web ACL WAFv2 de scope REGIONAL attaché à l'ALB

Sorties : `alb_dns_name`, `alb_zone_id`, `asg_name`, `instance_role_arn`.

### `data` — session 3

La persistance.

- Subnet group RDS sur les subnets privés données
- Instance PostgreSQL, `multi_az` piloté par variable
- Mot de passe maître géré par Secrets Manager
  (`manage_master_user_password`), donc absent du state
- Security group n'autorisant le 5432 que depuis le SG applicatif
- Fenêtres de sauvegarde et de maintenance

Sorties : `db_endpoint`, `db_secret_arn`, `db_security_group_id`.

### `edge` — session 4

La diffusion des contenus statiques.

- Bucket S3 des assets : accès public bloqué, versioning, chiffrement
- Distribution CloudFront avec Origin Access Control (OAC, pas l'ancien OAI)
- Politique de bucket n'autorisant que la distribution
- Certificat par défaut `*.cloudfront.net` : le projet n'a pas de nom de
  domaine, donc pas d'ACM ni de Route 53

Sorties : `assets_bucket_name`, `cloudfront_domain_name`.

### `observability` — session 4

La surveillance et les garde-fous de coût.

- Topic SNS + abonnement e-mail
- Alarmes CloudWatch : CPU de l'ASG, hôtes sains de l'ALB, 5xx, CPU et
  stockage libre RDS
- Log groups avec rétention courte
- Tableau de bord CloudWatch
- AWS Budgets mensuel avec notifications par palier

Sorties : `sns_topic_arn`, `dashboard_url`.

## Graphe de dépendances

```
networking
├── compute ──┐
├── data   ───┤
└── edge      │
              └── observability
```

`networking` est écrit et validé en premier ; `observability` en dernier,
puisqu'il référence les ressources de tous les autres.
