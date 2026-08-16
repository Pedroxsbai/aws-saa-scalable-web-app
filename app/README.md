# Application ASP.NET Core

API minimale (.NET 10, ASP.NET Core Minimal APIs), écrite et testée en
local. **Pas encore déployée sur l'ASG** — le launch template du module
`compute` fait toujours tourner le stub Python de test
(cf. `infra/modules/compute/main.tf`). Le câblage réel (artefact publié,
user-data mis à jour, remplacement des instances) est une étape distincte,
qui touche à l'infrastructure déjà en marche.

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

## Déploiement envisagé

Publication en artefact autonome (`dotnet publish -c Release
--self-contained false`), déposé sur S3, récupéré par le user-data du
launch template au démarrage de l'instance, lancé via un service systemd.
Pas de conteneur : ni ECS ni EKS ne sont dans le périmètre de ce projet.
Reste à écrire : le bucket S3 d'artefact (distinct du bucket d'assets du
module `edge`), la mise à jour du user-data, et la stratégie de
remplacement des instances de l'ASG au déploiement d'une nouvelle version.
