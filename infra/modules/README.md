# Modules Terraform

Cinq modules locaux, tous écrits. Aucun module externe (registry public) :
l'objectif pédagogique est d'écrire les ressources à la main pour la
préparation de la certification.

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

### `edge`

Voir [`edge/README.md`](edge/README.md). Le bucket S3 existe toujours ; la
distribution CloudFront est optionnelle (`enable_cloudfront`).

### `observability`

Voir [`observability/README.md`](observability/README.md). Référence les
sorties de tous les autres modules — écrit et appliqué en dernier.

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
