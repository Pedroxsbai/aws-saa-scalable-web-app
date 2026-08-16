# Diagramme d'architecture

Diagrammes en [Mermaid](https://mermaid.js.org/) (diagramme-as-code, rendu
natif sur GitHub) — cohérent avec une infrastructure elle-même entièrement
décrite en code. Reflète l'état **réellement déployé** en `eu-west-1`
(profil économique par défaut) ; les composants désactivés par défaut
(WAF, CloudFront) sont marqués comme tels, pas omis.

## Architecture réseau et applicative

```mermaid
flowchart TB
    User(("Utilisateur"))

    subgraph AWS["Compte AWS — eu-west-1"]
        subgraph VPC["VPC 10.0.0.0/16"]
            IGW["Internet Gateway"]

            subgraph AZa["AZ eu-west-1a"]
                subgraph PubA["Public 10.0.0.0/24"]
                    NAT["Instance NAT<br/>t3.micro"]
                end
                subgraph AppA["Private App 10.0.10.0/24"]
                    EC2["EC2 — ASP.NET Core<br/>(.NET 10, systemd)"]
                end
                subgraph DataA["Private Data 10.0.20.0/24"]
                    RDSa[("RDS PostgreSQL 16<br/>mono-AZ")]
                end
            end

            subgraph AZb["AZ eu-west-1b"]
                subgraph PubB["Public 10.0.1.0/24"]
                    ALB["Application<br/>Load Balancer"]
                end
                subgraph AppB["Private App 10.0.11.0/24"]
                    ASGnote["ASG : min 1 / max 4<br/>target tracking CPU"]
                end
                subgraph DataB["Private Data 10.0.21.0/24"]
                end
            end
        end

        SM["Secrets Manager<br/>(mot de passe RDS)"]
        S3assets["S3 — assets statiques"]
        S3artifacts["S3 — artefacts déploiement"]
        CF["CloudFront<br/>(désactivé par défaut)"]
        WAF["WAFv2<br/>(désactivé par défaut)"]
        SSM["Systems Manager<br/>(accès sans bastion)"]
        CW["CloudWatch<br/>5 alarmes + dashboard"]
        SNS["SNS"]
        Budgets["AWS Budgets<br/>filtré par tag Project"]
    end

    Operator(("Opérateur"))

    User -- "HTTP :80" --> ALB
    WAF -.->|optionnel| ALB
    ALB --> EC2
    EC2 -- "5432, SG scoped" --> RDSa
    EC2 -- "GetSecretValue" --> SM
    EC2 -.->|"sortie Internet<br/>(runtime .NET, S3)"| NAT
    NAT --> IGW
    IGW --> ALB
    EC2 -- "artefact au démarrage" --> S3artifacts
    CF -.->|optionnel, OAC| S3assets

    Operator -- "aws ssm start-session<br/>(pas de SSH)" --> SSM
    SSM --> EC2

    CW --> SNS
    Budgets --> SNS

    classDef disabled stroke-dasharray: 5 5,opacity:0.6
    class CF,WAF disabled
```

**Trois tiers de subnets** (public / privé applicatif / privé données),
2 AZ — cf. [ADR-001](../adr/001-nat-mode-variable.md) pour le choix de
l'instance NAT plutôt qu'une NAT Gateway managée, et
[ADR-002](../adr/002-region-eu-west-1.md) pour le choix de la région.

## Pipeline CI/CD

```mermaid
flowchart LR
    Dev(("Développeur"))

    subgraph GitHub["GitHub"]
        PR["Pull Request"]
        Main["Branche main"]
        PlanWF["Workflow plan.yml"]
        ApplyWF["Workflow apply.yml"]
    end

    subgraph AWS["AWS — OIDC, aucune clé longue durée"]
        RolePlan["Rôle IAM<br/>github_actions_plan<br/>(lecture seule)"]
        RoleApply["Rôle IAM<br/>github_actions_apply<br/>(lecture/écriture)"]
        Infra["Infrastructure<br/>eu-west-1"]
    end

    Dev -- "push branche" --> PR
    PR -- "déclenche" --> PlanWF
    PlanWF -- "AssumeRoleWithWebIdentity<br/>sub = repo:...:pull_request" --> RolePlan
    RolePlan -- "terraform plan" --> Infra

    PR -- "review + merge" --> Main
    Main -- "déclenche" --> ApplyWF
    ApplyWF -- "AssumeRoleWithWebIdentity<br/>sub = repo:...:ref/heads/main" --> RoleApply
    RoleApply -- "terraform apply<br/>-auto-approve" --> Infra
```

Détail des deux rôles et du scoping IAM :
[ADR-003](../adr/003-cicd-oidc-deux-roles.md).

## Sources

Fichiers `.mmd`/`.md` de ce dossier = source de vérité. Pour exporter en
PNG/SVG (ex. pour une présentation) :

```bash
npx -y @mermaid-js/mermaid-cli -i docs/diagrams/architecture.md -o docs/diagrams/architecture.png
```
