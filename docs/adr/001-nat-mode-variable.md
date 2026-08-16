# ADR-001 — Sortie Internet des subnets privés pilotée par une variable `nat_mode`

- **Statut** : accepté
- **Date** : 2026-08-16
- **Décideurs** : propriétaire du projet
- **Portée** : module `networking`, coût mensuel de la stack

## Contexte

Les instances EC2 de l'Auto Scaling Group vivent dans des subnets privés. Elles
ont besoin d'un accès sortant pour, au minimum :

- récupérer les mises à jour de paquets et le runtime .NET au démarrage
  (user-data) ;
- joindre les endpoints de service AWS : SSM (Session Manager), S3, CloudWatch
  Logs, Secrets Manager pour le mot de passe RDS.

Trois mécanismes répondent à ce besoin, avec des profils de coût et de
robustesse très différents. Or la contrainte structurante du projet est un
compte de formation crédité de 200 USD, à faire durer sur environ cinq
sessions de travail, incluant plusieurs cycles complets `apply`/`destroy`.

La NAT Gateway est le poste de coût dominant d'une architecture de ce type :
environ 0,045 USD/heure en eu-west-3, soit **~32 USD/mois pour une seule
gateway laissée en marche**, avant même le moindre gigaoctet transféré. Deux
gateways (une par AZ, la configuration recommandée en production) coûteraient
plus de 60 USD/mois — près d'un tiers du crédit total.

## Décision

L'implémentation n'est pas figée : la stratégie de sortie est exposée en
variable d'entrée `nat_mode`, de type `string`, contrainte par validation aux
trois valeurs `"gateway"`, `"instance"` et `"endpoints"`, avec `"gateway"`
pour valeur par défaut.

Une variable annexe `nat_high_availability` (bool, `false` par défaut) décide
du nombre de NAT : un seul dans la première AZ, ou un par AZ.

Le module `networking` implémentera les trois branches avec des `count`
pilotés par ces variables. Passer d'une stratégie à l'autre est un changement
de tfvars, pas un changement de code.

### Les trois modes

| Mode | Mécanisme | Coût mensuel estimé | Disponibilité | Accès Internet sortant |
|---|---|---|---|---|
| `gateway` | NAT Gateway managée dans le subnet public | ~32 USD (1 AZ) / ~64 USD (2 AZ) | Gérée par AWS, redondante dans son AZ | Complet |
| `instance` | EC2 `t4g.nano` faisant du routage NAT | ~3 USD | SPOF, restauration manuelle | Complet |
| `endpoints` | VPC endpoints uniquement (S3 gateway + interfaces SSM, Logs, Monitoring, Secrets Manager) | ~7,50 USD/mois par endpoint **et par AZ** — soit ~90 USD/mois pour 6 endpoints sur 2 AZ. L'endpoint S3 de type gateway est gratuit. | Redondants par AZ | **Aucun** — seuls les services AWS ciblés sont joignables |

### Valeur par défaut

`"gateway"`, parce que c'est la réponse attendue à la certification et la seule
que l'on puisse présenter à un jury sans réserve. Le mode par défaut doit être
le mode correct ; les modes économiques sont des dérogations explicites, prises
en connaissance de cause pendant les phases d'itération.

`nat_high_availability = false` en revanche : un seul NAT, dans l'AZ « a ».
C'est un SPOF assumé et documenté (voir *Conséquences*).

## Alternatives écartées

**Coder en dur la NAT Gateway.** Le plus simple, mais ~32 USD/mois qui tournent
même quand personne ne travaille sur le projet. Sur cinq sessions étalées dans
le temps, avec l'oubli de `destroy` qui finit toujours par arriver, c'est le
scénario qui vide le crédit avant la fin du projet.

**Coder en dur l'instance NAT.** Économique, et pédagogiquement intéressant :
comprendre `source_dest_check`, le routage et le masquerading a une vraie
valeur pour l'examen. Mais c'est une pratique dépréciée qu'on ne peut pas
présenter comme le choix nominal d'une architecture SAA, et cela ajoute une
instance à maintenir (AMI, patches, restauration).

**Se passer entièrement de NAT (endpoints seuls) en dur.** Le plus élégant sur
le plan de la sécurité : aucune route vers Internet depuis les subnets privés,
surface d'attaque réduite au strict nécessaire. Mais le user-data ne peut plus
installer le runtime .NET depuis Internet — il faudrait une AMI pré-construite
(Packer, ou EC2 Image Builder), ce qui déborde du périmètre. Surtout, le
calcul de coût joue contre ce mode : un endpoint d'interface est facturé par
ENI, donc **par AZ**. Six endpoints sur 2 AZ coûtent ~90 USD/mois, soit près du
triple d'une NAT Gateway unique. Le mode `endpoints` est le plus sûr, pas le
moins cher — c'est l'inverse de l'intuition de départ, et c'est ce qui a motivé
de garder `gateway` par défaut.

**Faire du sujet une décision de dernière minute.** Repousser le choix aurait
signifié écrire le module `networking` autour d'une hypothèse implicite, puis
le refactoriser sous contrainte budgétaire en fin de projet. Exposer la
variable dès la session 1 fige au contraire l'interface du module avant d'en
écrire une ligne.

## Conséquences

### Positives

- Le poste de coût dominant est réglable sans toucher au code : les phases
  d'itération intensive peuvent tourner en `endpoints` ou `instance`, la
  démonstration finale en `gateway`.
- Les trois modes obligent à implémenter les VPC endpoints SSM proprement dès
  le départ — ils sont indispensables en mode `endpoints`, et de toute façon
  requis par le choix « Session Manager plutôt que bastion ».
- La variable et cet ADR constituent en eux-mêmes un livrable : ils montrent
  au jury une décision d'architecture arbitrée sur des chiffres, pas un défaut
  de générateur de projet.

### Négatives et risques

- Le module `networking` porte trois chemins de code au lieu d'un. Plus de
  `count` conditionnels, donc plus de surface de bug et une lecture moins
  directe.
- **Les trois modes ne sont pas testés à parité.** Seul le mode par défaut sera
  exercé à chaque `apply`. Les modes `instance` et `endpoints` risquent de
  pourrir silencieusement. Mitigation : les traverser au moins une fois chacun
  et consigner le résultat dans ce fichier.
- Changer `nat_mode` sur une stack en marche détruit et recrée des routes :
  coupure de la sortie Internet des instances le temps du `apply`. Ce n'est pas
  une opération à chaud anodine.
- `nat_high_availability = false` signifie que la perte de l'AZ « a » prive de
  sortie Internet les instances de l'AZ « b », alors même que l'ALB et l'ASG
  continueraient de fonctionner. La HA de la stack est donc **partielle** et
  doit être présentée comme telle : c'est un arbitrage de coût, pas un oubli.

## Suivi

À compléter au fil des sessions :

- [ ] `gateway` — validé le : …
- [ ] `instance` — validé le : …
- [ ] `endpoints` — validé le : …

## Références

- Tarification VPC (NAT Gateway, endpoints) : https://aws.amazon.com/vpc/pricing/
- Comparaison NAT Gateway / instance NAT : https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-comparison.html
- Endpoints requis par Session Manager : https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-create-vpc.html
- Variable et validations : `infra/variables.tf`
