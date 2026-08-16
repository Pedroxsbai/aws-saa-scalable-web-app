# Module `data`

Instance RDS PostgreSQL, isolée dans les subnets privés données créés par le
module `networking` — aucune route sortante, jamais publiquement accessible.

## Ce qu'il fait

- `aws_db_subnet_group` sur les subnets `private-data`
- `aws_db_instance` PostgreSQL, avec :
  - `manage_master_user_password = true` — le mot de passe maître est généré
    et stocké par Secrets Manager, jamais dans le state ni dans une variable ;
  - `storage_encrypted = true`, chiffrement par la clé KMS gérée par AWS
    (`aws/rds`), sans coût additionnel ;
  - `publicly_accessible = false`, sans exception ;
  - export des logs PostgreSQL vers un log group CloudWatch dédié.

## Trade-off assumé : `skip_final_snapshot = true`

C'est ce qui permet à `terraform destroy` de réussir en une seule commande,
sans qu'il faille fournir un identifiant de snapshot final à la main. **À ne
jamais faire ainsi sur une base contenant des données réelles** — en
production, `skip_final_snapshot = false` et un `final_snapshot_identifier`
seraient obligatoires.

`backup_retention_days` (1 par défaut) reste néanmoins actif pendant toute la
durée de vie de l'instance : le PITR fonctionne tant que la base existe,
seule la sauvegarde de sortie est sacrifiée.

## Entrées principales

| Nom | Rôle |
|---|---|
| `private_data_subnet_ids` | subnets du subnet group, fournis par `networking` |
| `security_group_id` | SG `db-sg`, fourni par `networking` (5432 depuis `app-sg` uniquement) |
| `instance_class`, `allocated_storage` | dimensionnement, `db.t4g.micro` / 20 Go par défaut (plancher free tier) |
| `multi_az` | réplique synchrone ; double le coût, `false` par défaut |
| `deletion_protection` | doit rester `false` pour que `destroy` fonctionne |

## Sorties

`db_instance_id`, `db_endpoint`, `db_address`, `db_port`, `db_name`,
`db_secret_arn` — ce dernier consommé par le module `compute` pour donner au
rôle IAM d'instance un accès en lecture seule au secret, et à lui seul.

## Coût

`db.t4g.micro` + 20 Go gp3 mono-AZ : éligible free tier la première année du
compte ; hors free tier, environ 13 USD/mois. `multi_az = true` double ce
montant.
