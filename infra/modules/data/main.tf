# ---------------------------------------------------------------------------
# Module data — instance RDS PostgreSQL.
#
# Isolée dans les subnets privés données (aucune route sortante), jamais
# publiquement accessible, mot de passe maître géré par Secrets Manager.
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnets"
  subnet_ids = var.private_data_subnet_ids

  tags = {
    Name = "${var.name_prefix}-db-subnets"
  }
}

# Export des logs PostgreSQL vers CloudWatch — utile pour déboguer les échecs
# de connexion depuis l'application sans se connecter à la base.
resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/instance/${var.name_prefix}-db/postgresql"
  retention_in_days = var.log_retention_days
}

resource "aws_db_instance" "this" {
  identifier = "${var.name_prefix}-db"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.username

  # Mot de passe généré et géré par Secrets Manager : il n'apparaît jamais
  # dans le state ni dans une variable en clair. Rotation possible sans
  # toucher au code.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]

  # RDS n'est jamais accessible depuis Internet, quel que soit nat_mode.
  publicly_accessible = false

  multi_az = var.multi_az

  backup_retention_period = var.backup_retention_days
  # Fenêtres décalées pour ne jamais coïncider : la maintenance ne doit pas
  # tomber pendant une sauvegarde en cours.
  backup_window      = "03:00-04:00"
  maintenance_window = "mon:04:30-mon:05:30"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Pas de réplique en lecture, pas de Performance Insights : postes de coût
  # non nécessaires pour un projet de démonstration.
  performance_insights_enabled = false

  deletion_protection = var.deletion_protection

  # TRADE-OFF ASSUMÉ : aucun snapshot final à la destruction. C'est ce qui
  # permet à `terraform destroy` de réussir en une seule commande, sans étape
  # manuelle ni identifiant de snapshot à fournir. À ne jamais faire ainsi
  # sur une base contenant des données réelles.
  skip_final_snapshot = true

  # Applique les changements immédiatement plutôt qu'à la prochaine fenêtre
  # de maintenance — comportement attendu en itération de développement.
  apply_immediately = true

  tags = {
    Name = "${var.name_prefix}-db"
  }

  lifecycle {
    # Le mot de passe est régénéré par Secrets Manager ; ignorer les diffs
    # que Terraform verrait sinon sur ce champ géré hors bande.
    ignore_changes = [manage_master_user_password]
  }
}
