# ADR-002 — Migration de la région de déploiement, eu-west-3 → eu-west-1

- **Statut** : accepté
- **Date** : 2026-08-16
- **Décideurs** : propriétaire du projet
- **Portée** : `var.region`, ensemble de la stack applicative (le bucket de
  state S3 reste en eu-west-3, cf. *Conséquences*)

## Contexte

Le premier déploiement réel de la stack (session 3) a buté sur RDS :
`aws_db_instance` échoue systématiquement avec
`InstanceQuotaExceeded: You reached the maximum number of instances available
with free plan accounts`.

Investigation (détaillée dans
[`infra/modules/data/README.md`](../../infra/modules/data/README.md#blocage-connu--free-plan-aws)) :

- Le vrai quota de service RDS du compte, vérifié via `aws service-quotas`,
  est à 40 — largement suffisant.
- Le compte est sur le palier **"Free Plan"** d'AWS, qui impose ses propres
  plafonds techniques, indépendants des quotas de service et du crédit
  disponible.
- Reproduit à l'identique par un appel `aws rds create-db-instance` direct,
  hors Terraform : ce n'est donc pas une limitation de l'outil, mais du
  compte.
- En `eu-west-3`, le compte héberge déjà 2 instances RDS appartenant à
  d'autres projets du même propriétaire (`insighthub-dev-postgres`,
  `jobzyn-dev-postgres`) — le plafond Free Plan y est donc déjà atteint.
- Test décisif : le même appel `create-db-instance`, identique en tout point
  sauf `--region eu-west-1`, **réussit**. Le plafond est donc appliqué **par
  région**, pas au niveau du compte entier.

Le propriétaire du projet exclut explicitement d'upgrader le compte vers un
plan payant (risque perçu sur le crédit gratuit, après une mauvaise
expérience passée avec AWS Organizations sur un autre compte) et ne peut pas
libérer un slot en eu-west-3 : les deux instances existantes appartiennent à
des projets actifs, hors périmètre de celui-ci.

## Décision

L'ensemble de la stack applicative (VPC, subnets, NAT, ALB, ASG, RDS, et à
terme edge/observability) est déplacé de `eu-west-3` (Paris) vers
`eu-west-1` (Irlande), en modifiant uniquement `var.region` — aucune
ressource n'y était codée en dur.

RDS doit vivre dans le même VPC que les instances qui s'y connectent :
répartir le projet sur deux régions (EC2 en eu-west-3, RDS en eu-west-1)
aurait exigé du VPC peering inter-région, des routes et des security groups
supplémentaires, et de la latence — un coût de complexité largement
disproportionné par rapport au problème à résoudre. La migration porte donc
sur la stack entière, pas seulement sur RDS.

`eu-west-1` reste une région UE : le critère de conformité RGPD qui avait
motivé `eu-west-3` dans l'ADR initial du projet est préservé, seule la
justification technique change.

## Alternatives écartées

**Upgrader le compte vers un plan payant.** Lèverait la restriction
proprement et rendrait `eu-west-3` de nouveau viable. Explicitement écarté
par le propriétaire du projet : le crédit gratuit ne doit être menacé par
aucune action au niveau du compte, quelle que soit sa probabilité réelle de
risque.

**VPC peering entre eu-west-3 (compute) et eu-west-1 (RDS).** Techniquement
possible, mais ajoute une surface d'architecture (peering connection, routes
bidirectionnelles, DNS resolution cross-région, security groups à réconcilier
entre deux VPC) sans bénéfice pédagogique pour la certification SAA, pour
contourner une restriction de compte qui n'a rien à voir avec l'architecture
elle-même.

**Attendre / négocier la libération d'un slot en eu-west-3.** Les deux
instances existantes appartiennent à des projets actifs du même propriétaire ;
ni l'une ni l'autre n'est un candidat réaliste à la suppression pour ce
projet.

**Répartir arbitrairement RDS ailleurs qu'eu-west-1 (ex. eu-central-1).**
Aucune raison de préférer une autre région une fois qu'eu-west-1 s'est révélée
disponible et conforme RGPD ; multiplier les régions testées n'apporte rien.

## Conséquences

### Positives

- RDS peut désormais être créé : le blocage Free Plan ne s'applique qu'à
  `eu-west-3` sur ce compte.
- Aucun changement de code hors la valeur de `var.region` et les commentaires
  d'exemple (`az_suffixes`, `terraform.tfvars.example`) : la région n'était
  codée en dur nulle part dans les modules, ce qui valide a posteriori le
  choix de session 1 de tout paramétrer par variable.
- Le projet gagne une preuve concrète, utile pour la soutenance : diagnostic
  d'une contrainte de plateforme non documentée, testée méthodiquement
  (CLI directe hors Terraform, changement d'une seule variable à la fois),
  puis résolue sans compromis sur l'architecture cible.

### Négatives et risques

- **Le bucket de state reste en eu-west-3.** Le déplacer aurait exigé de
  recréer un bucket (nom globalement unique) et de migrer le state existant
  — complexité sans bénéfice fonctionnel, la région du backend S3 étant
  indépendante de celle des ressources qu'il décrit. Assumé et documenté
  dans `infra/backend.hcl.example`.
- Toute la stack précédemment déployée en eu-west-3 (session 3) a dû être
  détruite avant le redéploiement en eu-west-1 — aucune perte, elle avait
  déjà rempli son rôle de validation (`curl /health` → 200).
- Si `eu-west-1` venait à atteindre à son tour un plafond Free Plan (par
  exemple si un troisième projet y était déployé), le même problème
  réapparaîtrait. Rien dans ce projet ne garantit la disponibilité continue
  du quota — c'est une ressource partagée au niveau du compte AWS du
  propriétaire, hors du contrôle de ce repo.

## Références

- Blocage initial et preuve CLI : `infra/modules/data/README.md`
- ADR-001 (sortie Internet des subnets privés), non affecté par ce changement
- Variable : `infra/variables.tf` (`region`)
