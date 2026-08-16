# Application web scalable sur AWS — projet de graduation SAA

Projet de fin de parcours **AWS Solutions Architect Associate (Manara)** :
déploiement d'une application web hautement disponible et scalable sur AWS,
intégralement décrite en Terraform et livrée par GitHub Actions. Aucune
ressource n'est créée à la main, à l'exception du backend de state.

**Statut : session 1 sur ~5 — scaffolding.** L'infrastructure n'est pas encore
implémentée : `infra/` ne contient à ce stade que le contrat d'interface
(variables, providers, backend). Aucun `terraform apply` n'a été exécuté.

---

## Vue d'ensemble

| | |
|---|---|
| Région | `eu-west-3` (Paris) |
| Zones de disponibilité | 2 (`eu-west-3a`, `eu-west-3b`) |
| Runtime applicatif | ASP.NET Core sur EC2 (Amazon Linux 2023) |
| Base de données | RDS PostgreSQL 16 |
| Terraform | ≥ 1.9, provider AWS `~> 5.60` |
| State | S3 `tfstate-aws-saa-manara-<ACCOUNT_ID>` + verrou DynamoDB |
| Authentification CI | OIDC GitHub → IAM, aucune clé longue durée |

### Arborescence

```
aws-saa-scalable-web-app/
├── .github/
│   └── workflows/                   # pipelines CI/CD (session 5)
├── app/
│   └── README.md                    # application ASP.NET Core (session 3+)
├── docs/
│   ├── adr/
│   │   └── 001-nat-mode-variable.md # décision sur la sortie Internet privée
│   └── diagrams/                    # diagramme d'architecture (à venir)
├── infra/
│   ├── backend.tf                   # state distant S3 + verrou DynamoDB
│   ├── backend.hcl.example          # modèle de config backend (ID de compte)
│   ├── versions.tf                  # contraintes Terraform et providers
│   ├── providers.tf                 # provider aws, default_tags, locals
│   ├── variables.tf                 # 33 variables d'entrée, toutes validées
│   ├── terraform.tfvars.example     # modèle de configuration locale
│   └── modules/
│       └── README.md                # les 5 modules à venir et leur périmètre
├── Makefile                         # cycle de vie (référence, utilisé en CI)
├── make.ps1                         # équivalent PowerShell pour poste Windows
├── .gitignore
└── README.md
```

---

## Architecture

Diagramme : `docs/diagrams/` *(à produire en session 2, une fois le module
`networking` écrit)*.

Le trafic entre par un **Application Load Balancer** placé dans les subnets
publics, protégé par un **Web ACL WAFv2** portant les règles managées AWS. Il
répartit la charge sur un **Auto Scaling Group** d'instances EC2 réparties dans
les subnets privés applicatifs des deux AZ, avec une politique de scaling par
suivi de cible sur le CPU.

Les instances joignent une base **RDS PostgreSQL** isolée dans une troisième
paire de subnets privés, sans aucune route vers Internet. Le mot de passe
maître est généré et stocké par **Secrets Manager** ; il n'apparaît jamais dans
le state Terraform. Les instances y accèdent via leur rôle IAM.

Les **assets statiques** sont servis par **CloudFront** depuis un bucket S3
verrouillé, accessible uniquement par la distribution via Origin Access
Control. Le projet n'ayant pas de nom de domaine, CloudFront sert son
certificat `*.cloudfront.net` par défaut et l'ALB reste joignable sur son DNS
AWS — pas de Route 53, pas d'ACM.

L'accès administrateur aux instances passe par **Session Manager**, jamais par
SSH : pas de bastion, pas de key pair, pas de port 22 ouvert. Cela impose des
VPC endpoints SSM, qui sont créés quel que soit le mode de sortie retenu.

La sortie Internet des subnets privés est réglable par la variable `nat_mode`
(`gateway` | `instance` | `endpoints`) — c'est le principal levier de coût du
projet, arbitré dans [ADR-001](docs/adr/001-nat-mode-variable.md).

**Observabilité** : alarmes CloudWatch sur l'ASG, l'ALB et RDS, notifiées par
SNS, plus un budget AWS Budgets à seuils.

### Répartition réseau

| Tier | AZ a | AZ b | Rôle |
|---|---|---|---|
| Public | `10.0.0.0/24` | `10.0.1.0/24` | ALB, NAT |
| Privé applicatif | `10.0.10.0/24` | `10.0.11.0/24` | Instances de l'ASG |
| Privé données | `10.0.20.0/24` | `10.0.21.0/24` | RDS, aucune sortie |

VPC : `10.0.0.0/16`.

---

## Prérequis

### Outils locaux

| Outil | Version | Vérification |
|---|---|---|
| Terraform | ≥ 1.9 | `terraform version` |
| AWS CLI | v2 | `aws --version` |
| GNU make | facultatif sous Windows | `make --version` |
| terraform-docs | facultatif, pour `docs` | `terraform-docs --version` |

Sous Windows, `make` n'est en général pas disponible : utiliser `.\make.ps1`,
qui expose exactement les mêmes cibles.

### Identifiants AWS

```bash
aws configure          # ou un profil nommé : aws configure --profile saa
aws sts get-caller-identity
```

Région cible : `eu-west-3`. L'ID de compte n'est pas versionné : il vit
uniquement dans `infra/backend.hcl`, ignoré par git.

### Backend de state — à créer UNE SEULE FOIS avant le premier `init`

Le bucket et la table ne sont volontairement pas gérés par Terraform : le state
ne peut pas se stocker dans une ressource qu'il décrit lui-même. Ils survivent
donc à `terraform destroy`, ce qui est le comportement voulu.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws s3api create-bucket \
  --bucket "tfstate-aws-saa-manara-${ACCOUNT_ID}" \
  --region eu-west-3 \
  --create-bucket-configuration LocationConstraint=eu-west-3

aws s3api put-bucket-versioning \
  --bucket "tfstate-aws-saa-manara-${ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "tfstate-aws-saa-manara-${ACCOUNT_ID}" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket "tfstate-aws-saa-manara-${ACCOUNT_ID}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws dynamodb create-table \
  --table-name tf-lock-aws-saa-manara \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-3
```

Coût du backend : quelques centimes par mois.

---

## Déploiement

```bash
cp infra/backend.hcl.example infra/backend.hcl
# y remplacer <ACCOUNT_ID> par l'ID du compte AWS cible

cp infra/terraform.tfvars.example infra/terraform.tfvars
# renseigner au minimum alarm_email

make init        # ou .\make.ps1 init
make validate
make plan        # écrit infra/tfplan
make apply       # applique le plan enregistré
```

Cibles disponibles :

| Cible | Effet |
|---|---|
| `init` | initialise le backend S3, télécharge les providers |
| `fmt` / `fmt-check` | reformate / vérifie le formatage |
| `validate` | contrôle syntaxe et cohérence |
| `plan` | calcule le diff, l'enregistre dans `infra/tfplan` |
| `apply` | applique le plan enregistré |
| `destroy` | détruit toute la stack, avec confirmation |
| `docs` | régénère les README de modules via terraform-docs |
| `check` | `fmt-check` + `validate` + `plan` — à lancer avant commit |
| `cost` | estimation mensuelle via infracost |
| `clean` | supprime `.terraform/` et le plan local |

`apply` exige un plan préalable : aucune application ne se fait sur un diff
recalculé à la volée, y compris en CI.

---

## Nettoyage

```bash
make destroy     # ou .\make.ps1 destroy — demande de taper "destroy"
```

Toute la stack est conçue pour disparaître en une commande : `s3_force_destroy`
et `db_deletion_protection = false` sont des choix délibérés en ce sens. **Ne
pas les inverser** sans accepter que `destroy` échoue à mi-parcours et laisse
des ressources facturées derrière lui.

Ne sont **pas** détruits, et c'est voulu : le bucket de state, la table de
verrou, et les éventuels snapshots RDS finaux.

Vérification qu'il ne reste rien de facturé :

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=aws-saa-manara \
  --region eu-west-3
```

Tout ce que renvoie cette commande après un `destroy` réussi est un orphelin à
traiter à la main.

---

## Coûts estimés

Compte de formation crédité de **200 USD**, à faire durer sur environ cinq
sessions. Estimations pour `eu-west-3`, hors free tier et hors transfert
sortant, **si la stack tourne un mois entier** :

| Poste | Configuration par défaut | Coût mensuel |
|---|---|---|
| NAT Gateway | 1 seule, AZ a | ~32 USD |
| EC2 ASG | 2 × `t3.micro` | ~15 USD (0 si free tier) |
| ALB | 1, faible trafic | ~18 USD |
| RDS PostgreSQL | `db.t4g.micro`, mono-AZ, 20 Go | ~13 USD (0 si free tier) |
| WAF | 1 Web ACL + règles managées | ~6 USD |
| CloudFront | trafic de démonstration | < 1 USD |
| S3, CloudWatch, SNS | volumes marginaux | ~2 USD |
| Backend de state | S3 + DynamoDB | < 0,10 USD |
| **Total** | | **~85 USD/mois** |

Autrement dit : **la stack laissée en marche consomme le crédit en un peu plus
de deux mois.** D'où les règles de travail suivantes.

**Leviers, par ordre d'efficacité :**

1. `make destroy` à la fin de chaque session — de loin le plus important. Une
   stack détruite coûte zéro.
2. `nat_mode = "instance"` pendant les phases d'itération : ~29 USD/mois
   économisés à lui seul.
3. `enable_cloudfront = false` en développement : accessoirement ~15 minutes
   gagnées à chaque cycle apply/destroy.
4. `multi_az = false` (défaut) : Multi-AZ double le coût RDS.
5. `enable_waf = false` tant que la sécurité applicative n'est pas le sujet.

Le budget AWS Budgets configuré par la stack alerte à 50 %, 80 % et 100 % de
`budget_limit_usd` (40 USD par défaut). **Il alerte seulement : AWS Budgets
n'arrête rien tout seul.**

---

## Trade-offs assumés

Ces choix sont des compromis conscients, pas des oublis. Ils sont listés ici
parce qu'un projet d'architecture se juge autant sur ce qu'il assume que sur ce
qu'il implémente.

**Un seul NAT, donc haute disponibilité partielle.** `nat_high_availability`
est à `false` : la perte de l'AZ « a » prive de sortie Internet les instances
de l'AZ « b », alors même que l'ALB et l'ASG continueraient de servir le
trafic. Un second NAT coûterait ~32 USD/mois pour un scénario de panne qui ne
sera jamais exercé. Détail dans [ADR-001](docs/adr/001-nat-mode-variable.md).

**RDS mono-AZ par défaut.** Le basculement Multi-AZ est le mécanisme de HA que
la certification met le plus en avant, mais il double le coût de la base.
`multi_az = true` reste disponible pour la démonstration au jury ; l'état
nominal du projet est mono-AZ, avec une fenêtre d'indisponibilité assumée en
cas de panne d'AZ.

**Application sur EC2, pas de conteneurs.** ECS Fargate serait plus proche
d'une pratique actuelle. EC2 + ASG a été retenu parce que c'est le socle
explicitement évalué à l'examen SAA : launch templates, health checks,
politiques de scaling, rôles d'instance.

**Rétention de sauvegarde RDS à 1 jour.** Suffit à démontrer que le PITR
fonctionne, sans stocker des sauvegardes pour un environnement de formation.

**Rétention CloudWatch Logs à 7 jours.** Les logs sont le poste de coût le plus
sournois d'un compte de démonstration : ils s'accumulent silencieusement, y
compris après la destruction de la stack si les log groups ne sont pas gérés
par Terraform.

**`s3_force_destroy = true` et `db_deletion_protection = false`.** Deux
réglages qui seraient des fautes en production. Ils sont ici la condition pour
que `terraform destroy` réussisse en une commande — ce qui est, sur un compte
crédité, une garantie plus importante que la protection contre l'effacement
accidentel.

**HTTP en clair sur l'ALB.** Sans nom de domaine, pas de certificat ACM
possible pour l'ALB : le listener reste en HTTP. C'est acceptable pour une
démonstration, jamais pour du trafic réel. CloudFront, lui, sert bien en HTTPS
via son certificat par défaut.

**Un seul environnement.** Pas de séparation dev/staging/prod : la variable
`environment` existe et préfixe déjà toutes les ressources, mais un seul jeu
d'infrastructure est déployé. Le multi-environnement multiplierait le coût sans
rien démontrer de neuf.

---

## Feuille de route

| Session | Périmètre | État |
|---|---|---|
| 1 | Scaffolding : arborescence, backend, variables, Makefile, ADR-001 | ✅ terminée |
| 2 | Module `networking` : VPC, subnets, routage, les 3 modes NAT, endpoints SSM | à venir |
| 3 | Modules `compute` et `data` : ALB, ASG, WAF, RDS | à venir |
| 4 | Modules `edge` et `observability` : S3, CloudFront, alarmes, budget | à venir |
| 5 | CI/CD GitHub Actions avec OIDC, diagramme, documentation finale | à venir |

## Décisions d'architecture

- [ADR-001 — Sortie Internet des subnets privés pilotée par `nat_mode`](docs/adr/001-nat-mode-variable.md)
