# Module `edge`

Bucket S3 des assets statiques, distribution CloudFront optionnelle en
façade.

## Ce qu'il fait

- **Bucket S3** toujours créé : versioning, chiffrement SSE-S3, accès public
  totalement bloqué (`aws_s3_bucket_public_access_block`), nettoyage
  automatique des uploads multipart abandonnés après 7 jours.
- **Distribution CloudFront** créée uniquement si `enable_cloudfront = true`,
  avec :
  - Origin Access Control (OAC) — pas l'ancien OAI, déprécié ;
  - politique de cache managée AWS `CachingOptimized` (id
    `658327ea-f89d-4fab-a63d-7e88639e58f6`) ;
  - certificat par défaut `*.cloudfront.net` : pas de nom de domaine dans ce
    projet, donc pas d'ACM, pas de Route 53.
- **Politique de bucket** n'autorisant la lecture qu'à la distribution
  CloudFront précise (condition `AWS:SourceArn`), créée uniquement quand
  CloudFront existe. Le bucket reste privé et inaccessible tant que
  `enable_cloudfront = false`.

## Pourquoi le bucket existe même sans CloudFront

Séparer le stockage (bucket) de la diffusion (distribution) permet
d'itérer sur l'infra sans payer le temps de déploiement CloudFront
(~15 minutes en création comme en destruction) tant que ce n'est pas
nécessaire, sans pour autant perdre la capacité de préparer/tester des
uploads S3 en amont.

## Entrées principales

| Nom | Défaut | Rôle |
|---|---|---|
| `enable_cloudfront` | `false` | active la distribution ; coût quasi nul en usage de démonstration, mais cycle apply/destroy long |
| `cloudfront_price_class` | `PriceClass_100` | limite aux edges Amérique du Nord et Europe |
| `s3_force_destroy` | `true` | permet à `terraform destroy` de vider le bucket automatiquement |

## Sorties

`assets_bucket_name`, `assets_bucket_arn`, `cloudfront_domain_name` (`null`
si désactivé), `cloudfront_distribution_id` (`null` si désactivé, utile pour
une invalidation de cache manuelle).

## Coût

Bucket seul : quasi nul aux volumes de démonstration. Distribution
CloudFront active : quelques centimes/mois en trafic de démo, l'essentiel du
coût étant en réalité le temps perdu à chaque cycle apply/destroy plutôt que
la facture elle-même.
