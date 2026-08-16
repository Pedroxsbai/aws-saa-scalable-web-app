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

## Blocage résolu — migration vers eu-west-1

**Résolu le 2026-08-16.** L'instance RDS est déployée et `available` en
`eu-west-1` (`aws-saa-manara-dev-db`). Le blocage décrit ci-dessous, propre à
`eu-west-3` sur ce compte, ne s'est pas reproduit après le changement de
région — confirmant qu'il s'agissait d'un plafond appliqué par région, pas au
niveau du compte entier. Détail de la décision et des alternatives écartées :
[ADR-002](../../../docs/adr/002-region-eu-west-1.md).

### Historique du blocage — Free Plan AWS (eu-west-3)

Sur le compte utilisé pour ce projet, `terraform apply` échouait sur
`aws_db_instance.this` en `eu-west-3` avec :

```
InstanceQuotaExceeded: You reached the maximum number of instances
available with free plan accounts. To remove all limitations, upgrade
your account plan.
```

Ce n'est **pas** une erreur de code ni un quota AWS classique (le vrai quota
de service RDS, vérifié via `aws service-quotas get-service-quota --service-code
rds --quota-code L-7B6409FD`, est à 40). C'est une restriction technique
propre au **"Free Plan"** — un palier de compte AWS distinct de la facturation
et du crédit disponible : le compte plafonne à un nombre fixe d'instances RDS
(2, observé) quelle que soit la classe d'instance choisie. Le même mécanisme
bloque aussi les types EC2 non explicitement éligibles free tier au lancement
(`t4g.nano` refusé, `t4g.micro` accepté) — cf. le fix appliqué sur
`nat_instance_type` dans le module `networking`.

Sur ce compte, les 2 instances RDS existantes (`insighthub-dev-postgres`,
`jobzyn-dev-postgres`) appartiennent à d'autres projets actifs et ne peuvent
pas être libérées pour ce projet.

**Le blocage n'était pas propre à Terraform.** Un appel
direct `aws rds create-db-instance` avec les mêmes paramètres échoue à
l'identique :

```
$ aws rds create-db-instance --db-instance-identifier test-quota-check \
    --db-instance-class db.t3.micro --engine postgres --engine-version 16.9 \
    --master-username testadmin --manage-master-user-password \
    --allocated-storage 20 --no-publicly-accessible --region eu-west-3

An error occurred (InstanceQuotaExceeded) when calling the CreateDBInstance
operation: You reached the maximum number of instances available with free
plan accounts. To remove all limitations, upgrade your account plan.
```

C'est bien AWS qui rejette la requête à la validation de l'API
`CreateDBInstance`, avant toute création de ressource facturable — la
console web utilise le même endpoint et se heurtera au même refus. Le crédit
disponible sur le compte n'entre pas en jeu : ce n'est pas une limite de
dépense, c'est un plafond de nombre d'instances imposé par le palier "Free
Plan", indépendant du crédit et des quotas de service classiques (vérifié :
le vrai quota de service RDS est à 40). Aucune option Terraform, CLI ou
paramètre de la requête ne permet de le contourner.
