locals {
  name = "demo-hub"

  tags = {
    Terraform = true
  }
}

resource "random_pet" "this" {
  length = 1
}

module "flowlog_s3" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "4.6.0"
  count   = lookup(var.vpc_configs, "enable_flow_log", false) ? 1 : 0

  bucket        = format("%s-flowlog-%s", local.name, random_pet.this.id)
  force_destroy = lookup(var.vpc_configs, "flowlog_s3_force_destroy", false)

  control_object_ownership                 = true
  attach_elb_log_delivery_policy           = false
  attach_lb_log_delivery_policy            = true
  attach_access_log_delivery_policy        = false
  attach_deny_insecure_transport_policy    = true
  attach_deny_incorrect_encryption_headers = false
  attach_deny_unencrypted_object_uploads   = false
  attach_require_latest_tls_policy         = true

  lifecycle_rule = [
    {
      id      = "RetentionFlowlog"
      enabled = true
      filter = {
        prefix = "/"
      }
      expiration = {
        days = lookup(var.vpc_configs, "flowlog_s3_expiration_in_days", 7)
      }
    }
  ]

  tags = merge(local.tags, { Name = format("%s-flowlog-%s", local.name, random_pet.this.id) })
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.19.0"

  name = format("%s-vpc", local.name)

  cidr            = var.vpc_configs["cidr"]
  azs             = var.vpc_configs["azs"]
  public_subnets  = var.vpc_configs["public_subnets"]
  private_subnets = var.vpc_configs["private_subnets"]

  enable_dns_hostnames = true
  enable_dns_support   = true
  enable_dhcp_options  = true
  enable_nat_gateway   = lookup(var.vpc_configs, "enable_nat_gateway", false)
  single_nat_gateway   = lookup(var.vpc_configs, "single_nat_gateway", false)

  enable_flow_log                   = lookup(var.vpc_configs, "enable_flow_log", false)
  vpc_flow_log_iam_role_name        = format("%s-flowlog", local.name)
  flow_log_destination_type         = "s3"
  flow_log_max_aggregation_interval = 60
  flow_log_destination_arn          = try(module.flowlog_s3[0].s3_bucket_arn, null)
}

module "pritunl_vpn" {
  source = "../../"

  name               = format("%s-pritunl-vpn", local.name)
  vpc_id             = module.vpc.vpc_id
  azs                = module.vpc.azs
  public_subnet_ids  = module.vpc.public_subnets
  private_subnet_ids = module.vpc.private_subnets
  nat_public_ips     = module.vpc.nat_public_ips

  ec2_spec = {
    instance_type = "t3.micro"
  }

  enable_access_console_from_vpn = var.enable_access_console_from_vpn # work with 0.0.0.0/0 route only
  ingress_with_cidr_blocks = concat(
    [{
      from_port   = 12383
      to_port     = 12383
      protocol    = "udp"
      cidr_blocks = "0.0.0.0/0"
    }],
    var.enable_access_console_from_public ?
    [{
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
    }] : []
  )

  vpn_route53_records = {
    A = {
      name    = "vpn"
      type    = "A"
      zone_id = data.aws_route53_zone.this.id
    }
  }

  console_route53_records = {
    A = {
      name    = "vpn-console"
      type    = "A"
      zone_id = data.aws_route53_zone.this.id
    }
  }

  tags = merge(local.tags, { Name = format("%s-pritunl-vpn", local.name) })
}

data "aws_route53_zone" "this" {
  name = var.route53_hostzone
}
