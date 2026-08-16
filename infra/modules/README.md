# Modules Terraform

Cinq modules locaux prévus, écrits au fil des sessions. Aucun module externe
(registry public) : l'objectif pédagogique est d'écrire les ressources à la
main pour la préparation de la certification. `networking`, `data` et
`compute` sont écrits (session 3) ; `edge` et `observability` restent à venir.

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

## Modules écrits

### `networking`

Voir [`networking/README.md`](networking/README.md).

### `data`

Voir [`data/README.md`](data/README.md).

### `compute`

Voir [`compute/README.md`](compute/README.md). Utilise un stub HTTP en
placeholder tant que `app/` n'existe pas.

## Modules prévus

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
