# Application ASP.NET Core

Répertoire réservé — le projet applicatif est créé en session ultérieure,
une fois le réseau et la couche compute en place.

## Prévu

- Application web ASP.NET Core minimale, écoutant sur le port `8080`
  (cf. `var.app_port` dans `infra/variables.tf`)
- Endpoint `/health` renvoyant `200 OK` — cible du health check du target
  group ALB. Il doit rester léger : l'ALB l'appelle toutes les 30 secondes
  sur chaque instance.
- Endpoint `/db-check` vérifiant la connectivité PostgreSQL, pour démontrer
  que le chemin instance privée → RDS fonctionne
- Chaîne de connexion lue depuis Secrets Manager via le rôle IAM d'instance,
  jamais depuis un fichier de configuration commité
- Assets statiques servis par CloudFront, pas par l'application

## Déploiement envisagé

Publication en artefact autonome (`dotnet publish`), déposé sur S3, récupéré
par le user-data du launch template au démarrage de l'instance. Pas de
conteneur : ni ECS ni EKS ne sont dans le périmètre de ce projet.
