# Module `networking`

Socle réseau de la stack : VPC, subnets sur trois tiers, routage, sortie
Internet à trois modes, VPC endpoints et security groups inter-tiers.

Tous les autres modules en dépendent.

## Topologie

```
                        Internet
                            │
                    ┌───────┴───────┐
                    │      IGW      │
                    └───────┬───────┘
                            │
   ┌────────────────────────┴────────────────────────┐
   │  public          10.0.0.0/24    10.0.1.0/24     │   ALB, NAT
   │                  (AZ a)         (AZ b)          │
   └────────────────────────┬────────────────────────┘
                            │  0.0.0.0/0 → NAT (selon nat_mode)
   ┌────────────────────────┴────────────────────────┐
   │  private-app     10.0.10.0/24   10.0.11.0/24    │   ASG, endpoints
   │                  (AZ a)         (AZ b)          │
   └────────────────────────┬────────────────────────┘
                            │  route locale uniquement
   ┌────────────────────────┴────────────────────────┐
   │  private-data    10.0.20.0/24   10.0.21.0/24    │   RDS
   │                  (AZ a)         (AZ b)          │
   └─────────────────────────────────────────────────┘
```

Le tier `private-data` n'a **aucune** route vers l'extérieur : uniquement la
route locale du VPC. C'est la garantie qu'une base ne peut pas être exfiltrée
par une route mal placée.

## Tables de routage

| Table | Nombre | Route par défaut |
|---|---|---|
| `rt-public` | 1, partagée | → Internet Gateway |
| `rt-private-app` | **1 par AZ** | → NAT, ou aucune en mode `endpoints` |
| `rt-private-data` | 1, partagée | aucune |

Une table par AZ côté applicatif même sans haute disponibilité : c'est ce qui
permet de basculer `nat_high_availability` à `true` sans restructurer le
routage.

## Les trois modes de sortie

Voir [ADR-001](../../../docs/adr/001-nat-mode-variable.md) pour l'arbitrage.

### `gateway` (défaut)

NAT Gateway managée dans le subnet public, une EIP. Avec
`nat_high_availability = false`, une seule dans l'AZ `a` : les instances de
l'AZ `b` traversent l'AZ `a` pour sortir. Perdre l'AZ `a` leur coupe Internet.

### `instance`

Une EC2 `t4g.micro` sous Amazon Linux 2023 ARM, qui :

- désactive `source_dest_check` — sans quoi le VPC jette les paquets qu'elle
  est censée router ;
- active `net.ipv4.ip_forward` ;
- pose une règle `iptables` MASQUERADE sur l'interface par défaut, persistée
  via `iptables-services`.

Elle porte un rôle IAM `AmazonSSMManagedInstanceCore` : on s'y connecte par
Session Manager, pas par SSH. `user_data_replace_on_change = true` garantit
que modifier le script remplace bien l'instance.

### `endpoints`

Aucun NAT, aucune route par défaut sur les subnets applicatifs. Six endpoints
d'interface sont créés (`ssm`, `ssmmessages`, `ec2messages`, `logs`,
`monitoring`, `secretsmanager`), plus l'endpoint S3 de type gateway.

**Aucun accès Internet généraliste** : pas de `dnf update`, pas d'installation
du runtime .NET depuis Internet, pas d'appel d'API tierce. Ce mode suppose une
AMI pré-construite.

## Coût des endpoints — le piège

L'endpoint **S3 est de type gateway : gratuit**, et créé dans tous les modes.
Le trafic S3 ne consomme donc jamais le NAT.

Les endpoints **d'interface** sont facturés à l'heure **par ENI, donc par
AZ** : ~7,50 USD/mois chacun, ~15 USD/mois sur 2 AZ. Les trois endpoints SSM
coûtent à eux seuls **~45 USD/mois sur 2 AZ, soit plus qu'une NAT Gateway**.

D'où la règle appliquée par le module :

| Mode | Endpoints d'interface créés | Coût mensuel |
|---|---|---|
| `gateway` / `instance`, `enable_ssm_endpoints = false` (défaut) | aucun — SSM passe par le NAT | 0 |
| `gateway` / `instance`, `enable_ssm_endpoints = true` | 3 SSM | ~45 USD |
| `endpoints` | 6 | ~90 USD |

Le mode `endpoints` n'est donc **pas** le moins cher sur 2 AZ : il ne le
devient qu'en réduisant à une seule AZ ou en limitant la liste. Il se justifie
par la posture de sécurité (aucune route vers Internet), pas par le prix.

## Security groups

Déclarés ici parce qu'ils décrivent la topologie des flux entre tiers, pas le
comportement des ressources qu'ils protègent. Les modules `compute` et `data`
les consomment par leur id.

| SG | Entrant | Sortant |
|---|---|---|
| `alb-sg` | 80/443 depuis `alb_ingress_cidrs` | `app_port` vers `app-sg` |
| `app-sg` | `app_port` depuis `alb-sg` | tout |
| `db-sg` | 5432 depuis `app-sg` | **aucun** |
| `vpce-sg` | 443 depuis le CIDR du VPC | — |

Les règles inter-tiers référencent des **security groups**, jamais des CIDR :
les instances de l'ASG sont éphémères et changent d'IP à chaque remplacement.

`db-sg` n'a volontairement aucune règle d'egress — RDS n'initie jamais de
connexion sortante, et un SG sans règle d'egress bloque tout.

Aucune règle SSH nulle part : le port 22 est fermé, y compris depuis
l'intérieur du VPC.

## Flow Logs

`enable_flow_logs = false` par défaut. Ils sont l'outil de diagnostic à activer
quand une instance privée n'atteint pas ce qu'elle devrait, mais ils sont
facturés à l'ingestion et se remplissent vite. À activer ponctuellement, puis
à couper.

## Entrées principales

| Nom | Type | Défaut | Rôle |
|---|---|---|---|
| `name_prefix` | string | — | préfixe de nommage |
| `vpc_cidr` | string | — | CIDR du VPC |
| `azs` | list(string) | — | AZ complètes ; l'index 0 héberge le NAT unique |
| `public_subnet_cidrs` | list(string) | — | un CIDR par AZ |
| `private_app_subnet_cidrs` | list(string) | — | un CIDR par AZ |
| `private_data_subnet_cidrs` | list(string) | — | un CIDR par AZ |
| `nat_mode` | string | — | `gateway` \| `instance` \| `endpoints` |
| `nat_high_availability` | bool | `false` | un NAT par AZ |
| `nat_instance_type` | string | `t4g.micro` | famille ARM, éligible free tier obligatoire |
| `enable_ssm_endpoints` | bool | `false` | endpoints SSM malgré un NAT |
| `app_port` | number | `8080` | port applicatif |
| `alb_ingress_cidrs` | list(string) | `["0.0.0.0/0"]` | accès public à l'ALB |
| `db_port` | number | `5432` | port PostgreSQL |
| `enable_flow_logs` | bool | `false` | diagnostic réseau |

## Sorties

`vpc_id`, `vpc_cidr`, `public_subnet_ids`, `private_app_subnet_ids`,
`private_data_subnet_ids`, `alb_security_group_id`, `app_security_group_id`,
`db_security_group_id`, `nat_mode`, `nat_public_ips`, `internet_gateway_id`,
`interface_endpoint_ids`.

## Points d'attention

- Changer `nat_mode` sur une stack en marche recrée les routes : coupure de la
  sortie Internet pendant l'`apply`.
- `nat_instance_type` doit rester une famille **ARM** (`t4g`, `c7g`) :
  l'AMI sélectionnée est `al2023-ami-2023.*-arm64`. Un `t3.nano` échouerait au
  démarrage.
- Sur un compte AWS "Free Plan", seuls les types explicitement éligibles free
  tier sont acceptés au lancement — `t4g.nano` est refusé par l'API
  (`InvalidParameterCombination: not eligible for Free Tier`), `t4g.micro`
  passe. Vérifier `aws ec2 describe-instance-types --filters
  Name=free-tier-eligible,Values=true` en cas de doute.
- Les subnets `private-data` n'ont pas de route sortante : une instance RDS ne
  peut pas télécharger d'extension depuis Internet. Ce n'est pas un bug.
