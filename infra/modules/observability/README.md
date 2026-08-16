# Module `observability`

SNS, alarmes CloudWatch, tableau de bord, AWS Budgets. Écrit en dernier
parce qu'il référence les ressources de tous les autres modules.

## Ce qu'il fait

### SNS — point de fan-out unique

Un seul topic (`aws_sns_topic.alerts`) reçoit toutes les notifications :
alarmes CloudWatch et alertes de budget. L'abonnement e-mail
(`aws_sns_topic_subscription`) n'est créé que si `alarm_email` n'est pas
vide, et reste `PendingConfirmation` tant que le lien reçu par e-mail n'a
pas été cliqué — comportement SNS standard, rien à faire côté Terraform.

Le topic porte une politique de ressource explicite autorisant
`budgets.amazonaws.com` et `cloudwatch.amazonaws.com` à y publier. Contrairement
à CloudWatch (même compte, autorisé par défaut), **AWS Budgets a besoin
d'une permission explicite** sur le topic pour y publier — omission
fréquente qui casse silencieusement les notifications de budget.

### Alarmes CloudWatch

Cinq alarmes, seuils fixés en `locals` (non exposés en variables — pas de
besoin de les piloter depuis `tfvars` à ce stade) :

| Alarme | Métrique | Seuil |
|---|---|---|
| `asg-cpu-high` | `AWS/EC2 CPUUtilization` (ASG) | > 80 %, 10 min |
| `alb-unhealthy-hosts` | `AWS/ApplicationELB UnHealthyHostCount` | ≥ 1, 3 min |
| `alb-5xx` | `AWS/ApplicationELB HTTPCode_Target_5XX_Count` | > 10 sur 5 min |
| `rds-cpu-high` | `AWS/RDS CPUUtilization` | > 80 %, 10 min |
| `rds-free-storage-low` | `AWS/RDS FreeStorageSpace` | < 2 Gio |

Les dimensions ALB (`LoadBalancer`, `TargetGroup`) utilisent les
**`arn_suffix`** exposés par le module `compute` — pas les ARN complets, que
CloudWatch n'accepte pas comme dimensions pour ces métriques.

### Tableau de bord CloudWatch

Un dashboard (`${name_prefix}-overview`) avec 4 widgets : CPU ASG, requêtes
et 5xx ALB, CPU et stockage libre RDS, cibles saines/non saines. Pas de
widget NAT — l'instance n'expose pas de métrique CloudWatch dédiée pertinente
au-delà du CPU EC2 standard.

### AWS Budgets

Un budget mensuel (`budget_limit_usd`), filtré par tag `Project` (via
`cost_filter` sur `TagKeyValue`) pour ne suivre **que le coût de cette
stack** — important puisque le compte héberge d'autres projets. Notifie via
le topic SNS à chaque palier de `budget_alert_thresholds` (50/80/100 % par
défaut). **N'arrête rien** : AWS Budgets alerte, il ne coupe jamais de
ressources.

## Entrées principales

| Nom | Rôle |
|---|---|
| `asg_name`, `alb_arn_suffix`, `target_group_arn_suffix`, `db_instance_id` | fournis par `compute` et `data` |
| `alarm_email` | vide = pas d'abonnement e-mail, le topic et les alarmes existent quand même |
| `project_name` | filtre le budget par tag, pour isoler le coût de cette stack sur un compte partagé |

## Sorties

`sns_topic_arn`, `dashboard_name`, `dashboard_url` (lien direct console),
`budget_name`.

## Coût

SNS, alarmes CloudWatch et dashboard : quasi nuls (les 10 premières alarmes
et le premier dashboard sont dans le free tier CloudWatch standard). AWS
Budgets : gratuit.
