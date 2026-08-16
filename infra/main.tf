# ---------------------------------------------------------------------------
# Composition de la stack.
#
# La racine ne déclare aucune ressource directement : elle assemble les modules
# et leur passe les variables d'entrée. Les modules restants (compute, data,
# edge, observability) viendront s'ajouter ici au fil des sessions.
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
