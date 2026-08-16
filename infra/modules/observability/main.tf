# ---------------------------------------------------------------------------
# Module observability — SNS, alarmes CloudWatch, tableau de bord, budget.
#
# Écrit en dernier parce qu'il référence les ressources de tous les autres
# modules (compute, data). Les seuils d'alarme sont volontairement des
# constantes internes (locals), pas des variables : les exposer ajouterait de
# la configurabilité pour un besoin qui ne s'est pas manifesté.
# ---------------------------------------------------------------------------

data "aws_region" "current" {}

locals {
  cpu_high_threshold_pct        = 80
  unhealthy_hosts_threshold     = 1
  http_5xx_threshold_per_period = 10
  rds_cpu_high_threshold_pct    = 80
  # 2 Gio — sous ce seuil, RDS approche l'épuisement du stockage alloué.
  rds_free_storage_threshold_bytes = 2 * 1024 * 1024 * 1024
}

# ===========================================================================
# SNS — point de fan-out unique pour toutes les notifications
# ===========================================================================

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"

  tags = {
    Name = "${var.name_prefix}-alerts"
  }
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email

  # L'abonnement reste "PendingConfirmation" tant que le lien reçu par
  # e-mail n'a pas été cliqué — comportement SNS standard, rien à faire côté
  # Terraform.
}

# AWS Budgets est un service tiers du point de vue de SNS : contrairement à
# CloudWatch (même compte, autorisé par défaut), il a besoin d'une permission
# explicite sur le topic pour y publier.
data "aws_iam_policy_document" "alerts_topic_policy" {
  statement {
    sid    = "AllowBudgetsPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid    = "AllowCloudWatchAlarmsPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic_policy.json
}

# ===========================================================================
# Alarmes CloudWatch
# ===========================================================================

resource "aws_cloudwatch_metric_alarm" "asg_cpu_high" {
  alarm_name          = "${var.name_prefix}-asg-cpu-high"
  alarm_description   = "CPU moyen de l'ASG au-dessus de ${local.cpu_high_threshold_pct}% pendant 10 minutes."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = local.cpu_high_threshold_pct
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = var.asg_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-asg-cpu-high"
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${var.name_prefix}-alb-unhealthy-hosts"
  alarm_description   = "Au moins ${local.unhealthy_hosts_threshold} cible(s) de l'ALB signalée(s) unhealthy."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = local.unhealthy_hosts_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-alb-unhealthy-hosts"
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name_prefix}-alb-5xx"
  alarm_description   = "Plus de ${local.http_5xx_threshold_per_period} erreurs 5xx cible sur 5 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = local.http_5xx_threshold_per_period
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-alb-5xx"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.name_prefix}-rds-cpu-high"
  alarm_description   = "CPU RDS au-dessus de ${local.rds_cpu_high_threshold_pct}% pendant 10 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = local.rds_cpu_high_threshold_pct
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-rds-cpu-high"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  alarm_name          = "${var.name_prefix}-rds-free-storage-low"
  alarm_description   = "Stockage RDS libre sous 2 Gio."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = local.rds_free_storage_threshold_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-rds-free-storage-low"
  }
}

# ===========================================================================
# Tableau de bord CloudWatch
# ===========================================================================

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ASG — CPU moyen"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.asg_name]
          ]
          period = 300
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB — Requêtes et erreurs 5xx"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix],
          ]
          period = 300
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "RDS — CPU et stockage libre"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_id],
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.db_instance_id, { yAxis = "right" }],
          ]
          period = 300
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ALB — Cibles saines / non saines"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix],
          ]
          period = 60
          stat   = "Maximum"
        }
      },
    ]
  })
}

# ===========================================================================
# AWS Budgets — alerte, ne coupe rien
# ===========================================================================

resource "aws_budgets_budget" "monthly" {
  name         = "${var.name_prefix}-monthly-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Filtre par tag Project : le budget ne suit que le coût de cette stack,
  # pas l'ensemble du compte (qui héberge d'autres projets).
  cost_filter {
    name = "TagKeyValue"
    # Format attendu par AWS Budgets : "user:<TagKey>$<TagValue>", séparateur
    # dollar littéral. format() évite l'ambiguïté d'échappement de $${...}
    # en interpolation Terraform.
    values = [format("user:Project$%s", var.project_name)]
  }

  dynamic "notification" {
    for_each = var.budget_alert_thresholds

    content {
      comparison_operator       = "GREATER_THAN"
      notification_type         = "ACTUAL"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
    }
  }
}
