# ---------------------------------------------------------------------------
# Module compute — ALB, Auto Scaling Group, WAF optionnel.
#
# Pas de nom de domaine (cf. README « Trade-offs ») : le listener ALB reste en
# HTTP simple, sans certificat ACM.
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_region" "current" {}

# ===========================================================================
# Bucket S3 d'artefacts de déploiement
#
# Distinct du bucket d'assets statiques du module edge : celui-ci porte le
# livrable `dotnet publish` (zip), pas des fichiers servis au public.
# Jamais accessible publiquement — seul le rôle d'instance peut le lire.
#
# L'objet lui-même (releases/latest.zip) N'EST PAS géré par Terraform : le
# publier à chaque `apply` sans changement de code ferait un no-op bruyant,
# et un changement de code ne doit pas nécessiter de plan Terraform. Publié
# par `make deploy-app` (dotnet publish + aws s3 cp), en dehors du state.
# ===========================================================================

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name_prefix}-artifacts-${random_id.artifacts_suffix.hex}"
  force_destroy = var.s3_force_destroy

  tags = {
    Name = "${var.name_prefix}-artifacts"
  }
}

resource "random_id" "artifacts_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  # Permet de revenir à l'artefact précédent (aws s3api copy-object depuis
  # une version antérieure) sans avoir eu besoin de le republier.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role_policy" "app_artifact_read" {
  name = "${var.name_prefix}-app-artifact-read"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.artifacts.arn}/*"
    }]
  })
}

# ===========================================================================
# Application Load Balancer
# ===========================================================================

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  # false pour un projet destiné à disparaître par `terraform destroy` : la
  # protection empêcherait la suppression de l'ALB.
  enable_deletion_protection = false

  tags = {
    Name = "${var.name_prefix}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  name     = "${var.name_prefix}-app-tg"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.name_prefix}-app-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ===========================================================================
# Rôle IAM d'instance
#
# Accès Session Manager (pas de bastion) + lecture seule du secret RDS.
# Aucun accès en écriture, aucun accès à d'autres secrets.
# ===========================================================================

resource "aws_iam_role" "app" {
  name = "${var.name_prefix}-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.name_prefix}-app-role"
  }
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app_db_secret" {
  name = "${var.name_prefix}-app-db-secret-read"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.db_secret_arn
    }]
  })
}

resource "aws_iam_role_policy" "app_logs" {
  name = "${var.name_prefix}-app-logs-write"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.app.arn}:*"
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name_prefix}-app-profile"
  role = aws_iam_role.app.name
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/ec2/${var.name_prefix}-app"
  retention_in_days = var.log_retention_days
}

# ===========================================================================
# Launch template + Auto Scaling Group
# ===========================================================================

resource "aws_launch_template" "app" {
  name_prefix   = "${var.name_prefix}-app-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  vpc_security_group_ids = [var.app_security_group_id]

  metadata_options {
    http_tokens   = "required" # IMDSv2 obligatoire
    http_endpoint = "enabled"
  }

  monitoring {
    enabled = var.enable_detailed_monitoring
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = 8
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Récupère l'artefact publié (dotnet publish, zippé) depuis S3, installe
  # le runtime ASP.NET Core (téléchargé depuis Internet — nécessite une
  # sortie NAT ; indisponible en nat_mode = "endpoints" sans AMI
  # pré-construite, cf. modules/networking/README.md), et lance l'app comme
  # service systemd sous un utilisateur dédié non-root.
  #
  # DB_SECRET_ARN transite en clair dans l'environnement du service : ce
  # n'est qu'un pointeur, jamais le secret déchiffré lui-même (résolu par
  # l'application à l'exécution via son rôle IAM). Voir app/README.md.
  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -euxo pipefail

    dnf install -y unzip

    # Runtime ASP.NET Core seul (pas le SDK complet) via le script officiel
    # Microsoft — AL2023 ne publie pas de paquet dotnet dans ses dépôts par
    # défaut. Installé dans /opt, pas /usr/local, pour rester isolé du
    # système.
    curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    bash /tmp/dotnet-install.sh --channel 10.0 --runtime aspnetcore --install-dir /opt/dotnet
    ln -sf /opt/dotnet/dotnet /usr/local/bin/dotnet

    id -u appuser &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin appuser

    mkdir -p /opt/app
    aws s3 cp "s3://${aws_s3_bucket.artifacts.id}/releases/latest.zip" /tmp/app.zip --region ${data.aws_region.current.name}
    unzip -o /tmp/app.zip -d /opt/app
    rm -f /tmp/app.zip
    chown -R appuser:appuser /opt/app

    cat > /etc/systemd/system/awssaaapp.service <<UNIT
    [Unit]
    Description=Application ASP.NET Core aws-saa-manara
    After=network.target

    [Service]
    Type=simple
    User=appuser
    WorkingDirectory=/opt/app
    ExecStart=/opt/dotnet/dotnet /opt/app/AwsSaaApp.dll
    Restart=always
    RestartSec=5
    Environment=APP_PORT=${var.app_port}
    Environment=DB_HOST=${var.db_address}
    Environment=DB_PORT=${var.db_port}
    Environment=DB_NAME=${var.db_name}
    Environment=DB_SECRET_ARN=${var.db_secret_arn}
    Environment=ASPNETCORE_ENVIRONMENT=Production
    # AL2023 minimal n'a pas libicu installé ; sans ça .NET échoue au
    # démarrage (FailFast "Couldn't find a valid ICU package"). L'app ne
    # fait aucun formatage dépendant de la culture : mode invariant plutôt
    # que d'ajouter une dépendance système.
    Environment=DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now awssaaapp
  EOT
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.name_prefix}-app"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  name = "${var.name_prefix}-asg"

  vpc_zone_identifier = var.private_app_subnet_ids
  target_group_arns   = [aws_lb_target_group.app.arn]

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  # ELB plutôt qu'EC2 : une instance dont le processus a planté mais dont le
  # système répond toujours doit être remplacée, pas considérée saine.
  health_check_type = "ELB"
  # 180s : le user_data télécharge et installe le runtime ASP.NET Core
  # depuis Internet avant de démarrer le service — plus long que l'ancien
  # stub Python préinstallé. Une valeur trop courte remplacerait des
  # instances saines mais encore en train de démarrer.
  health_check_grace_period = 180

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-app"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "${var.name_prefix}-asg-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.asg_target_cpu_utilization
  }
}

# ===========================================================================
# WAF — optionnel
# ===========================================================================

resource "aws_wafv2_web_acl" "alb" {
  count = var.enable_waf ? 1 : 0

  name  = "${var.name_prefix}-alb-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-common-rule-set"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-alb-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.name_prefix}-alb-waf"
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  count = var.enable_waf ? 1 : 0

  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.alb[0].arn
}
