# Application ASP.NET Core

API minimale (.NET 10, ASP.NET Core Minimal APIs). **Déployée et vérifiée en
production** : `curl` sur l'ALB confirme `/`, `/health` et `/db-check` tous
`200`, ce dernier avec une vraie connexion RDS de bout en bout
(`{"status":"ok","latency_ms":396}`).

## Endpoints

| Route | Rôle |
|---|---|
| `GET /` | statut basique, JSON |
| `GET /health` | cible du health check ALB — rapide, sans dépendance externe |
| `GET /db-check` | vérifie la connectivité PostgreSQL de bout en bout (Secrets Manager → Npgsql → `SELECT 1`) |

`/health` reste volontairement sans dépendance : l'ALB l'appelle toutes les
30 secondes sur chaque instance, une vérification DB à cette fréquence
serait coûteuse et fragile. `/db-check` sert de diagnostic à la demande.

## Configuration — variables d'environnement

| Variable | Rôle | Défaut |
|---|---|---|
| `APP_PORT` | port d'écoute Kestrel | `8080` (= `var.app_port`) |
| `DB_HOST`, `DB_PORT`, `DB_NAME` | connexion PostgreSQL | `localhost` / `5432` / `appdb` |
| `DB_SECRET_ARN` | ARN du secret RDS (Secrets Manager) — chemin production | — |
| `DB_USERNAME`, `DB_PASSWORD` | identifiants directs — chemin développement local uniquement | — |

**Jamais de mot de passe en dur dans le code ou un fichier commité.** En
production, seul `DB_SECRET_ARN` est fourni (par le user-data de l'instance,
lui-même alimenté par les outputs Terraform) ; le rôle IAM de l'instance a un
accès `secretsmanager:GetSecretValue` scopé à ce secret précis
(`infra/modules/compute/main.tf`). En local, `DB_USERNAME`/`DB_PASSWORD`
(déjà présents dans `Properties/launchSettings.json` avec des valeurs
factices) évitent d'avoir besoin d'identifiants AWS pour lancer l'app.

`DbCredentialsProvider` (`Services/DbCredentialsProvider.cs`) résout les
identifiants dans cet ordre : `DB_USERNAME`/`DB_PASSWORD` s'ils sont
présents, sinon `DB_SECRET_ARN` via Secrets Manager. Le secret RDS pouvant
tourner (rotation automatique), il est mis en cache 5 minutes, pas figé au
démarrage.

## Lancer en local

```bash
cd app
dotnet run
```

Écoute sur `http://localhost:8080`. Sans PostgreSQL local, `/db-check`
répond `503` avec un message d'erreur clair (`Failed to connect to
127.0.0.1:5432`) — comportement attendu, testé.

Pour tester `/db-check` avec un vrai PostgreSQL local (docker) :

```bash
docker run -d --name pg-dev -e POSTGRES_PASSWORD=devpassword \
  -e POSTGRES_USER=appadmin -e POSTGRES_DB=appdb -p 5432:5432 postgres:16
dotnet run
curl http://localhost:8080/db-check
```

## Déploiement

Publication en artefact autonome (`dotnet publish -c Release
--self-contained false`), déposée sur un bucket S3 dédié (distinct du bucket
d'assets du module `edge`), récupérée par le user-data du launch template au
démarrage de l'instance, lancée via un service systemd sous un utilisateur
dédié non-root (`appuser`). Pas de conteneur : ni ECS ni EKS ne sont dans le
périmètre de ce projet.

```bash
make deploy-app     # ou .\make.ps1 deploy-app
```

Publie l'artefact puis déclenche un `instance refresh` sur l'ASG. **Avec
`asg_min_size = 1` (profil économique), l'instance unique est remplacée
l'une après l'autre : coupure de service de quelques dizaines de secondes**
pendant le remplacement. `asg_min_size = 2` (profil démonstration)
éliminerait cette coupure.

### Panne rencontrée en déploiement réel — ICU manquant sur AL2023

Le premier déploiement a échoué : le service `systemd` bouclait en
`core-dump`, health check ALB en échec permanent (502). Diagnostic via
Session Manager (`journalctl -u awssaaapp`) :

```
Couldn't find a valid ICU package installed on the system.
```

Amazon Linux 2023 minimal n'embarque pas `libicu`, dont .NET a besoin pour
la globalisation (formatage de dates, tri de chaînes selon la culture).
L'app n'utilise aucune fonctionnalité dépendante de la culture : plutôt que
d'ajouter une dépendance système, `InvariantGlobalization` est activé dans
`AwsSaaApp.csproj`, doublé par `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`
dans le service systemd (défense en profondeur — le second suffit seul,
sans même republier l'artefact). Invisible à `dotnet build`/`dotnet run` en
local (Windows n'a pas ce problème) : découvert uniquement par un
déploiement réel sur AL2023.
