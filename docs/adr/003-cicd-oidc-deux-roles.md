# ADR-003 — CI/CD par OIDC, deux rôles séparés par privilège, apply automatique

- **Statut** : accepté
- **Date** : 2026-08-16
- **Décideurs** : propriétaire du projet
- **Portée** : `infra/cicd.tf`, `.github/workflows/plan.yml`, `.github/workflows/apply.yml`

## Contexte

Le brief impose une authentification GitHub Actions → AWS par OIDC, sans clé
longue durée. Restait à trancher trois questions structurantes :

1. Un seul rôle IAM pour tout, ou plusieurs séparés par niveau de privilège ?
2. `terraform apply` déclenché comment — automatiquement au push sur `main`,
   ou derrière une validation manuelle supplémentaire ?
3. Jusqu'où scoper les permissions du ou des rôles ?

## Décision

### Deux rôles, séparés par déclencheur GitHub

- `github_actions_plan` — lecture seule. Assumable uniquement par les runs
  déclenchés sur une pull request (`sub = repo:.../pull_request` dans le
  token OIDC).
- `github_actions_apply` — lecture + écriture. Assumable **uniquement** par
  les runs déclenchés par un push sur `main` (`sub =
  repo:.../ref:refs/heads/main`). Aucune pull request, même depuis ce dépôt,
  ne peut l'assumer.

La condition porte sur le champ `sub` du token OIDC lui-même, vérifié par
AWS STS à l'échange — pas sur une logique applicative dans le workflow qui
pourrait être contournée en modifiant le YAML dans une PR malveillante.

### `apply` automatique au push sur `main`, sans validation supplémentaire

Décision explicite du propriétaire du projet : la revue de la pull request
avant merge **est** le point de contrôle, pas une étape distincte après coup.
Ajouter un `environment` GitHub avec approbation manuelle aurait dupliqué ce
contrôle sans réduire le risque réel (celui qui approuve la PR est aussi
celui qui approuverait l'apply).

### Provider OIDC référencé, pas créé

Un provider OIDC pour `token.actions.githubusercontent.com` existait déjà
sur le compte (créé par un autre projet du même propriétaire) — vérifié via
`aws iam list-open-id-connect-providers` avant d'écrire le moindre code. AWS
n'autorise qu'un seul provider par URL et par compte : `infra/cicd.tf` le
référence donc via `data.aws_iam_openid_connect_provider`, pas via une
ressource `aws_iam_openid_connect_provider`. Le créer aurait échoué
(`EntityAlreadyExists`) et, plus important, aurait fait entrer une ressource
partagée avec d'autres projets dans le state de celui-ci — un
`terraform destroy` ne doit jamais pouvoir l'emporter.

### Scoping des permissions — pragmatique, documenté

- **IAM** (rôles, instance profiles) : restreint aux ressources préfixées
  `${local.name_prefix}-*`. C'est le service où une fuite de privilège serait
  la plus grave (capacité à créer un rôle avec des permissions arbitraires),
  et le seul où l'ARN permet un scoping par nom fiable dès l'écriture de la
  politique.
- **Secrets Manager** : restreint au préfixe `rds!*`, imposé par AWS à tout
  secret créé via `manage_master_user_password` — jamais un secret
  applicatif nommé librement.
- **S3** : restreint au préfixe `${local.name_prefix}-*`, couvre le bucket
  d'assets malgré son suffixe aléatoire inconnu à l'écriture de la politique.
- **State backend** (S3 + DynamoDB) : restreint aux ARN exacts du bucket et
  de la table, dérivés de la même convention que `backend.hcl.example`.
- **EC2, ELB, Auto Scaling, RDS, CloudFront, SNS, CloudWatch, Logs,
  Budgets, SSM** : `Resource = "*"`, en lecture pour le rôle plan (actions
  `Describe*`/`Get*`/`List*`, à faible risque), en lecture+écriture pour le
  rôle apply. Ces API ne proposent pas de mécanisme de scoping par nom ou
  tag utilisable de façon fiable à la fois pour la *création* (le nom/tag
  n'existe pas encore au moment de l'appel) et la *lecture* ultérieure dans
  ce projet précis.

## Alternatives écartées

**Un seul rôle read+write pour tout.** Plus simple à écrire, mais un run
déclenché par une pull request non fiable (fork externe, dépendance
compromise dans un futur `package.json`/`requirements.txt`) aurait alors les
mêmes droits qu'un push mergé sur `main`. La séparation par `sub` coûte peu
et élimine complètement cette classe de risque.

**Clés d'accès IAM long-lived stockées en secret GitHub.** Explicitement
exclu par le brief. OIDC élimine la rotation manuelle et la fenêtre
d'exposition d'une clé qui fuiterait.

**`AdministratorAccess` ou `PowerUserAccess` managées AWS.** Rapide à poser,
mais sans rapport avec ce que la stack manipule réellement — un run
compromis aurait accès à l'intégralité du compte, y compris aux ressources
des deux autres projets qui y vivent. Écarté au profit d'un scoping sur
mesure, même imparfait.

**Scoping par tag (`aws:ResourceTag/Project`) plutôt que par nom, pour
EC2/RDS/ELB.** Plus élégant en théorie et documenté dans les cours SAA, mais
inapplicable proprement ici : les actions de *création* (`ec2:CreateVpc`,
`rds:CreateDBInstance`...) ne peuvent être conditionnées que par
`aws:RequestTag` (le tag qu'on s'apprête à poser), pas par
`aws:ResourceTag` (qui suppose que la ressource existe déjà) — il aurait
fallu deux jeux de conditions différents par action selon si elle crée ou
modifie une ressource existante, pour un gain de sécurité marginal sur un
compte de formation. Jugé disproportionné pour ce projet ; noté ici comme
piste d'amélioration si le projet devait évoluer vers un contexte de
production.

**Validation manuelle (GitHub Environment) avant apply.** Écarté par le
propriétaire du projet : la review de PR est déjà le point de contrôle
humain ; en ajouter un second dilue la responsabilité sans réduire le risque.

## Ce que la validation locale n'a pas détecté

`terraform validate` et un `plan`/`apply` local ne testent que la syntaxe et
la cohérence des références entre ressources — jamais les permissions IAM
réelles, puisque l'opérateur local (`devops-admin`) a tous les droits sur le
compte. Le premier run réel de chaque rôle CI a donc servi de test
d'intégration à part entière, et a immédiatement révélé cinq lacunes
invisibles jusque-là :

1. **Le `sub` OIDC réel n'est pas `repo:owner/repo:...`.** Documenté partout
   comme tel, y compris dans la documentation GitHub citée en référence —
   mais le token émis pour ce compte inclut les identifiants numériques
   immuables du propriétaire et du dépôt :
   `repo:owner@owner_id/repo@repo_id:ref:refs/heads/main`. Découvert en
   inspectant le champ `userIdentity.principalId` d'un événement CloudTrail
   `AssumeRoleWithWebIdentity` refusé — la seule façon de voir la valeur
   réelle envoyée par GitHub. Corrigé en `StringLike` avec un wildcard sur
   la partie identifiant plutôt qu'un match exact sur le nom.
2. **`iam:ListOpenIDConnectProviders` et `iam:ListRoles` refusent tout
   scoping par ressource.** Ce sont des actions qui énumèrent le compte par
   construction ; IAM exige `Resource = "*"` même si on ne s'intéresse qu'à
   un provider ou un rôle précis. Les scoper sur un ARN exact ne produit pas
   une erreur à l'écriture de la politique, mais un refus silencieux à
   l'exécution.
3. **La nomenclature des actions IAM S3 est incohérente.** `s3:GetBucketVersioning`
   contient « Bucket », `s3:GetAccelerateConfiguration` non — sans logique
   apparente. Une liste d'actions nommées une à une se fait contourner par
   la moindre action interne non anticipée qu'appelle le provider AWS lors
   du rafraîchissement d'un `aws_s3_bucket` (accélération, réplication,
   politique de requête...). Remplacé par des wildcards `s3:Get*` / `s3:Put*`
   scopés au préfixe du projet plutôt que par une énumération fragile.
4. **`iam:UpdateAssumeRolePolicy` ≠ `iam:UpdateRole`.** Deux actions IAM
   distinctes ; seule la première permet de modifier le document de
   confiance d'un rôle. Sans elle, le rôle `apply` ne pouvait pas mettre à
   jour son propre document de confiance ni celui du rôle `plan` — révélé en
   laissant le pipeline appliquer sa propre correction du point 1.
5. **`budgets:ListTagsForResource` n'a pas d'équivalent `Describe*`.**
   Contrairement à la plupart des services où les tags se lisent via
   l'action `Describe*` générique déjà accordée, AWS Budgets exige une
   action dédiée, à ajouter explicitement.

Une collision de verrou DynamoDB transitoire (`ConditionalCheckFailedException`)
est également apparue une fois, deux workflows ayant tenté d'acquérir le
lock à quelques secondes d'intervalle — comportement normal du mécanisme de
verrouillage, pas un bug : un simple nouveau run après libération du lock a
suffi.

Chacune de ces cinq lacunes a été corrigée, réappliquée localement pour ne
pas laisser le compte dans un état intermédiaire, puis vérifiée par un
nouveau run réel avant de passer à la suivante — jamais corrigée « à
l'aveugle » sans confirmation.

## Conséquences

### Positives

- Scénario d'attaque le plus probable (dépendance compromise dans une PR
  externe) neutralisé structurellement : le rôle assumable par une PR ne
  peut rien créer, modifier ni détruire.
- Aucune clé longue durée nulle part — ni en local (déjà le cas via `aws
  configure` du poste de l'opérateur), ni en CI.
- Bootstrap propre : le provider OIDC partagé n'a pas eu besoin d'être
  recréé ni importé dans le state, évitant tout risque de collision avec
  les deux autres projets du compte.

### Négatives et risques assumés

- **`apply` automatique sans garde-fou technique supplémentaire.** Un merge
  sur `main` avec un `terraform.tfvars` mal réglé (ex. `nat_high_availability
  = true` et `multi_az = true` combinés par erreur) applique directement,
  sans seconde chance avant que la ressource ne soit créée et facturée. Le
  filet de sécurité est humain (review de PR), pas technique.
- **Scoping `Resource = "*"` sur la majorité des services applicatifs.** Le
  rôle apply peut, en théorie, modifier n'importe quelle ressource EC2, RDS,
  ELB, CloudFront, SNS, CloudWatch ou Budgets du compte — y compris celles
  des deux autres projets qui y vivent. Assumé comme compromis
  coût/bénéfice pour ce projet ; **ne pas répliquer tel quel dans un
  contexte de production multi-équipes**, où le scoping par tag évoqué
  ci-dessus deviendrait nécessaire malgré sa complexité.
- Deux rôles à maintenir plutôt qu'un : toute permission manquante doit être
  ajoutée aux deux `data.aws_iam_policy_document` concernés si elle est
  requise en lecture ET en écriture.

## Références

- Politiques : `infra/cicd.tf`
- Workflows : `.github/workflows/plan.yml`, `.github/workflows/apply.yml`
- Documentation OIDC AWS ↔ GitHub Actions : https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
