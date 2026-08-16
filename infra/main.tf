# ---------------------------------------------------------------------------
# Composition de la stack.
#
# La racine ne déclare aucune ressource directement : elle assemble les modules
# et leur passe les variables d'entrée. Les modules restants (edge,
# observability) viendront s'ajouter ici au fil des sessions.
# ---------------------------------------------------------------------------

module "networking" {
  source = "./modules/networking"

  name_prefix = local.name_prefix

  vpc_cidr                  = var.vpc_cidr
  azs                       = local.azs
  public_subnet_cidrs       = var.public_subnet_cidrs
  private_app_subnet_cidrs  = var.private_app_subnet_cidrs
  private_data_subnet_cidrs = var.private_data_subnet_cidrs

  nat_mode              = var.nat_mode
  nat_high_availability = var.nat_high_availability
  nat_instance_type     = var.nat_instance_type
  enable_ssm_endpoints  = var.enable_ssm_endpoints

  app_port          = var.app_port
  alb_ingress_cidrs = var.alb_ingress_cidrs

  enable_flow_logs         = var.enable_flow_logs
  flow_logs_retention_days = var.log_retention_days
}

module "data" {
  source = "./modules/data"

  name_prefix             = local.name_prefix
  private_data_subnet_ids = module.networking.private_data_subnet_ids
  security_group_id       = module.networking.db_security_group_id

  instance_class        = var.db_instance_class
  engine_version        = var.db_engine_version
  multi_az              = var.multi_az
  allocated_storage     = var.db_allocated_storage
  db_name               = var.db_name
  username              = var.db_username
  backup_retention_days = var.db_backup_retention_days
  deletion_protection   = var.db_deletion_protection
  log_retention_days    = var.log_retention_days
}

module "compute" {
  source = "./modules/compute"

  name_prefix = local.name_prefix
  vpc_id      = module.networking.vpc_id

  public_subnet_ids      = module.networking.public_subnet_ids
  private_app_subnet_ids = module.networking.private_app_subnet_ids

  alb_security_group_id = module.networking.alb_security_group_id
  app_security_group_id = module.networking.app_security_group_id

  app_port      = var.app_port
  instance_type = var.instance_type

  asg_min_size               = var.asg_min_size
  asg_max_size               = var.asg_max_size
  asg_desired_capacity       = var.asg_desired_capacity
  asg_target_cpu_utilization = var.asg_target_cpu_utilization

  db_secret_arn = module.data.db_secret_arn

  enable_waf                 = var.enable_waf
  enable_detailed_monitoring = var.enable_detailed_monitoring
  log_retention_days         = var.log_retention_days
}
