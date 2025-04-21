data "aws_caller_identity" "current" {}

data "aws_ami" "this" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"]
}

data "aws_ec2_instance_type" "this" {
  instance_type = lookup(var.ec2_spec, "instance_type", null)
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

locals {
  raise_require_nat_ips = var.enable_access_console_from_vpn ? length(var.nat_public_ips) == 0 ? file("var.nat_public_ips is require if var.enable_access_console_from_vpn = true") : [] : []

  sg_rules        = var.ingress_with_cidr_blocks
  all_ports       = local.sg_rules[*].to_port
  unique_ports    = distinct(local.sg_rules[*].to_port)
  unique_sg_rules = [for port in local.unique_ports : local.sg_rules[index(local.all_ports, port)]]
  target_group = [for i in local.unique_sg_rules : {
    port     = i.to_port
    protocol = i.protocol
  }]

  tags = merge(
    {
      Terraform = true
    },
    var.tags
  )
}

/* -------------------------------------------------------------------------- */
/*                                  IAM Role                                  */
/* -------------------------------------------------------------------------- */
data "aws_iam_policy_document" "ec2" {
  statement {
    sid       = "IamPassRole"
    actions   = ["iam:PassRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid = "ListEc2AndListInstanceProfiles"
    actions = [
      "iam:ListInstanceProfiles",
      "ec2:Describe*",
      "ec2:Search*",
      "ec2:Get*"
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = format("%s-ec2", var.name)
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = merge(local.tags, { Name = format("%s-ec2", var.name) })
}

resource "aws_iam_role_policy" "this" {
  name = format("%s-policy", var.name)
  role = aws_iam_role.this.id

  policy = data.aws_iam_policy_document.ec2.json
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = merge(var.default_ec2_policies, var.additional_profile_policies)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "this" {
  name = format("%s-ec2", var.name)
  role = aws_iam_role.this.name

  tags = merge(local.tags, { Name = format("%s-ec2", var.name) })
}

/* -------------------------------------------------------------------------- */
/*                                   VPN NLB                                  */
/* -------------------------------------------------------------------------- */
# Can also use for web access if public ip of user are in sg
module "vpn_lb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.3.0"

  name                     = format("%s-lb", var.name)
  vpc_id                   = var.vpc_id
  ingress_with_cidr_blocks = var.ingress_with_cidr_blocks
  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = -1
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = merge(local.tags, { Name = format("%s-lb", var.name) })
}

resource "aws_lb" "vpn" {
  name               = format("%s-lb", var.name)
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids
  security_groups    = [module.vpn_lb_sg.security_group_id]

  tags = merge(local.tags, { Name = format("%s-lb", var.name) })
}

resource "aws_lb_target_group" "vpn" {
  count = length(local.target_group)

  name     = format("%s-tg-%s", var.name, count.index)
  port     = local.target_group[count.index].port
  protocol = upper(local.target_group[count.index].protocol)
  vpc_id   = var.vpc_id

  health_check {
    port     = lookup(local.target_group[count.index], "health_check_port", 443)
    protocol = upper(lookup(local.target_group[count.index], "health_check_protocol", "TCP"))
  }

  tags = merge(local.tags, { Name = format("%s-tg-%s", var.name, count.index) })
}

resource "aws_lb_listener" "vpn" {
  count = length(local.target_group)

  load_balancer_arn = aws_lb.vpn.arn
  port              = local.target_group[count.index].port
  protocol          = upper(local.target_group[count.index].protocol)

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vpn[count.index].arn
  }
}

/* -------------------------------------------------------------------------- */
/*                                 VPN WEB NLB                                */
/* -------------------------------------------------------------------------- */
module "web_lb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.3.0"
  count   = var.enable_access_console_from_vpn ? 1 : 0

  name   = format("%s-cs-sg", var.name)
  vpc_id = var.vpc_id
  ingress_with_cidr_blocks = concat(
    var.enable_access_console_from_vpn ? [
      {
        rule        = "https-443-tcp"
        description = "Allow access from nat"
        cidr_blocks = join(",", [for ip in var.nat_public_ips : format("%s/32", ip)])
      }
    ] : []
  )
  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = -1
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = merge(local.tags, { Name = format("%s-cs-sg", var.name) })
}

# If you want fully manage and access from IaC to console
# You can use this feature
## If you are to lazy to make new nlb, you just manually assign your ip address to ec2's sg | public lb's sg == i use the same
## because user -> (web) vpn's ip; cannot force to go under vpn it will break VPN
#### so user -(web)-> eth0 (your normal network interface)
#### which will make your traffic not getting ec2 ->(nat's ip) 
#### so it will be etho0 ---> isp ip -> X sg|ec2, if not allow on 0.0.0.0/0 or your isp ip from var.ingress_with_cidr_blocks
## So we need another lb for accessing console, working with 0.0.0.0/0 -> vpn -> nat ->
## but you need to wait and it may be costly
## Base on compliance, if you can do it by adding you ip either by manual or ingress_with_cidr_blocks it also ok
#### In this case i just want to switch var and apply (enable_access_console_from_public, enable_access_console_from_vpn)
#### also i cannot change thing on console so need to run from robot account which not assumable from me.
resource "aws_lb" "web" {
  count = var.enable_access_console_from_vpn ? 1 : 0

  name               = format("%s-web", var.name)
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids
  security_groups    = [module.web_lb_sg[0].security_group_id]

  tags = merge(local.tags, { Name = format("%s-web", var.name) })
}

resource "aws_lb_target_group" "web" {
  count = var.enable_access_console_from_vpn ? 1 : 0

  name     = format("%s-web-tg", var.name)
  port     = 443
  protocol = "TCP"
  vpc_id   = var.vpc_id

  health_check {
    port     = 443
    protocol = "TCP"
  }

  tags = merge(local.tags, { Name = format("%s-web-tg", var.name) })
}

resource "aws_lb_listener" "web" {
  count = var.enable_access_console_from_vpn ? 1 : 0

  load_balancer_arn = aws_lb.web[0].arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web[0].arn
  }
}

/* -------------------------------------------------------------------------- */
/*                                 VPN Server                                 */
/* -------------------------------------------------------------------------- */
module "ec2_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.3.0"

  name   = format("%s-ec2", var.name)
  vpc_id = var.vpc_id
  ingress_with_source_security_group_id = concat(
    [
      for tg in local.target_group : {
        description              = "Allow access from vpn lb"
        from_port                = tg.port
        to_port                  = tg.port
        protocol                 = tg.protocol
        source_security_group_id = module.vpn_lb_sg.security_group_id
      } if !(var.enable_access_console_from_vpn && tg.port == 443)
    ],
    var.enable_access_console_from_vpn ? [
      {
        description              = "Allow health check from vpn lb"
        from_port                = 443
        to_port                  = 443
        protocol                 = "tcp"
        source_security_group_id = module.vpn_lb_sg.security_group_id
      },
      {
        description              = "Allow health check from console lb"
        from_port                = 443
        to_port                  = 443
        protocol                 = "tcp"
        source_security_group_id = module.web_lb_sg[0].security_group_id
      }
    ] : []
  )

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = -1
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = merge(local.tags, { Name = format("%s-ec2", var.name) })
}

resource "aws_launch_template" "this" {
  name_prefix = var.name

  ebs_optimized          = lookup(var.ec2_spec, "ebs_optimized", var.default_ec2_spec["ebs_optimized"])
  image_id               = lookup(var.ec2_spec, "image_id", data.aws_ami.this.id)
  instance_type          = lookup(var.ec2_spec, "instance_type", null)
  key_name               = lookup(var.ec2_spec, "key_name", null)
  vpc_security_group_ids = [module.ec2_sg.security_group_id]

  user_data = base64encode(
    templatefile(
      "${path.module}/user_data.sh",
      {
        efs_id = module.efs.id
      }
    )
  )

  default_version                      = lookup(var.ec2_spec, "default_version", var.default_ec2_spec["default_version"])
  update_default_version               = lookup(var.ec2_spec, "update_default_version", var.default_ec2_spec["update_default_version"])
  disable_api_termination              = lookup(var.ec2_spec, "disable_api_termination", var.default_ec2_spec["disable_api_termination"])
  instance_initiated_shutdown_behavior = lookup(var.ec2_spec, "instance_initiated_shutdown_behavior", var.default_ec2_spec["instance_initiated_shutdown_behavior"])
  kernel_id                            = lookup(var.ec2_spec, "kernel_id", var.default_ec2_spec["kernel_id"])
  ram_disk_id                          = lookup(var.ec2_spec, "ram_disk_id", var.default_ec2_spec["ram_disk_id"])

  dynamic "block_device_mappings" {
    for_each = lookup(var.ec2_spec, "block_device_mappings", {})

    content {
      device_name  = block_device_mappings.value.device_name
      no_device    = lookup(block_device_mappings.value, "no_device", null)
      virtual_name = lookup(block_device_mappings.value, "virtual_name", null)

      dynamic "ebs" {
        for_each = flatten([lookup(block_device_mappings.value, "ebs", [])])
        content {
          delete_on_termination = lookup(ebs.value, "delete_on_termination", null)
          encrypted             = lookup(ebs.value, "encrypted", null)
          kms_key_id            = lookup(ebs.value, "kms_key_id", null)
          iops                  = lookup(ebs.value, "iops", null)
          throughput            = lookup(ebs.value, "throughput", null)
          snapshot_id           = lookup(ebs.value, "snapshot_id", null)
          volume_size           = lookup(ebs.value, "volume_size", null)
          volume_type           = lookup(ebs.value, "volume_type", null)
        }
      }
    }
  }

  dynamic "capacity_reservation_specification" {
    for_each = lookup(var.ec2_spec, "capacity_reservation_specification", {})

    content {
      capacity_reservation_preference = lookup(capacity_reservation_specification.value, "capacity_reservation_preference", null)

      dynamic "capacity_reservation_target" {
        for_each = try([capacity_reservation_specification.value.capacity_reservation_target], [])
        content {
          capacity_reservation_id = lookup(capacity_reservation_target.value, "capacity_reservation_id", null)
        }
      }
    }
  }

  dynamic "cpu_options" {
    for_each = lookup(var.ec2_spec, "cpu_options", null) == null ? [] : [lookup(var.ec2_spec, "cpu_options")]

    content {
      core_count       = cpu_options.value.core_count
      threads_per_core = cpu_options.value.threads_per_core
    }
  }

  dynamic "credit_specification" {
    for_each = lookup(var.ec2_spec, "credit_specification", null) == null ? [] : [lookup(var.ec2_spec, "credit_specification")]

    content {
      cpu_credits = credit_specification.value.cpu_credits
    }
  }

  dynamic "elastic_gpu_specifications" {
    for_each = lookup(var.ec2_spec, "elastic_gpu_specifications", null) == null ? [] : [lookup(var.ec2_spec, "elastic_gpu_specifications")]

    content {
      type = elastic_gpu_specifications.value.type
    }
  }

  dynamic "elastic_inference_accelerator" {
    for_each = lookup(var.ec2_spec, "elastic_inference_accelerator", null) == null ? [] : [lookup(var.ec2_spec, "elastic_inference_accelerator")]

    content {
      type = elastic_inference_accelerator.value.type
    }
  }

  dynamic "enclave_options" {
    for_each = lookup(var.ec2_spec, "enclave_options", null) == null ? [] : [lookup(var.ec2_spec, "enclave_options")]

    content {
      enabled = enclave_options.value.enabled
    }
  }

  dynamic "hibernation_options" {
    for_each = lookup(var.ec2_spec, "hibernation_options", null) == null ? [] : [lookup(var.ec2_spec, "hibernation_options")]

    content {
      configured = hibernation_options.value.configured
    }
  }

  iam_instance_profile {
    name = null
    arn  = aws_iam_instance_profile.this.arn
  }


  dynamic "instance_market_options" {
    for_each = lookup(var.ec2_spec, "instance_market_options", null) == null ? [] : [lookup(var.ec2_spec, "instance_market_options")]

    content {
      market_type = instance_market_options.value.market_type

      dynamic "spot_options" {
        for_each = lookup(instance_market_options.value, "spot_options", null) != null ? [instance_market_options.value.spot_options] : []
        content {
          block_duration_minutes         = lookup(spot_options.value, "block_duration_minutes", null)
          instance_interruption_behavior = lookup(spot_options.value, "instance_interruption_behavior", null)
          max_price                      = lookup(spot_options.value, "max_price", null)
          spot_instance_type             = lookup(spot_options.value, "spot_instance_type", null)
          valid_until                    = lookup(spot_options.value, "valid_until", null)
        }
      }
    }
  }

  dynamic "license_specification" {
    for_each = lookup(var.ec2_spec, "license_specification", null) == null ? [] : [lookup(var.ec2_spec, "license_specification")]

    content {
      license_configuration_arn = license_specifications.value.license_configuration_arn
    }
  }

  dynamic "metadata_options" {
    for_each = lookup(var.ec2_spec, "metadata_options", null) == null ? [] : [lookup(var.ec2_spec, "metadata_options")]

    content {
      http_endpoint               = lookup(metadata_options.value, "http_endpoint", null)
      http_tokens                 = lookup(metadata_options.value, "http_tokens", null)
      http_put_response_hop_limit = lookup(metadata_options.value, "http_put_response_hop_limit", null)
      http_protocol_ipv6          = lookup(metadata_options.value, "http_protocol_ipv6", null)
      instance_metadata_tags      = lookup(metadata_options.value, "instance_metadata_tags", null)
    }
  }

  dynamic "monitoring" {
    for_each = lookup(var.ec2_spec, "monitoring", null) == null ? [] : [lookup(var.ec2_spec, "monitoring")]

    content {
      enabled = lookup(var.ec2_spec, "enable_monitoring", var.default_ec2_spec["enable_monitoring"])
    }
  }

  dynamic "placement" {
    for_each = lookup(var.ec2_spec, "placement", null) == null ? [] : [lookup(var.ec2_spec, "placement")]

    content {
      affinity          = lookup(placement.value, "affinity", null)
      availability_zone = lookup(placement.value, "availability_zone", null)
      group_name        = lookup(placement.value, "group_name", null)
      host_id           = lookup(placement.value, "host_id", null)
      spread_domain     = lookup(placement.value, "spread_domain", null)
      tenancy           = lookup(placement.value, "tenancy", null)
      partition_number  = lookup(placement.value, "partition_number", null)
    }
  }

  dynamic "network_interfaces" {
    for_each = lookup(var.ec2_spec, "network_interfaces", null) == null ? [] : [lookup(var.ec2_spec, "network_interfaces")]

    content {
      associate_carrier_ip_address = lookup(network_interfaces.value, "associate_carrier_ip_address", null)
      associate_public_ip_address  = lookup(network_interfaces.value, "associate_public_ip_address", null)
      delete_on_termination        = lookup(network_interfaces.value, "delete_on_termination", null)
      description                  = lookup(network_interfaces.value, "description", null)
      device_index                 = lookup(network_interfaces.value, "device_index", null)
      interface_type               = lookup(network_interfaces.value, "interface_type", null)
      ipv4_addresses               = try(network_interfaces.value.ipv4_addresses, [])
      ipv4_address_count           = lookup(network_interfaces.value, "ipv4_address_count", null)
      ipv6_addresses               = try(network_interfaces.value.ipv6_addresses, [])
      ipv6_address_count           = lookup(network_interfaces.value, "ipv6_address_count", null)
      network_interface_id         = lookup(network_interfaces.value, "network_interface_id", null)
      private_ip_address           = lookup(network_interfaces.value, "private_ip_address", null)
      security_groups              = lookup(network_interfaces.value, "security_groups", null)
      subnet_id                    = lookup(network_interfaces.value, "subnet_id", null)
    }
  }

  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])
    content {
      resource_type = tag_specifications.key
      tags          = local.tags
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_autoscaling_group" "this" {
  name_prefix         = format("%s-asg", var.name)
  vpc_zone_identifier = var.private_subnet_ids

  # THIS IS VPN STANDALONEEEE SERVERRRRRRRRRRRR
  desired_capacity = 1
  max_size         = 1
  min_size         = 1

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  target_group_arns = concat(aws_lb_target_group.vpn.*.arn, try(aws_lb_target_group.web[0].*.arn, [])) # TODO CHECK THIS THING

  dynamic "tag" {
    for_each = merge(local.tags, { Name = var.name })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "random_pet" "this" {
  length = 1
}

module "kms" {
  source  = "terraform-aws-modules/kms/aws"
  version = "3.1.1"

  aliases               = ["efs/${format("%s-kms", var.name)}"]
  description           = "EFS customer managed key"
  enable_default_policy = true

  deletion_window_in_days = 30

  tags = merge(local.tags, { Name = format("%s-kms", var.name) })
}

module "efs" {
  source  = "terraform-aws-modules/efs/aws"
  version = "1.8.0"

  name           = format("%s-efs", var.name)
  creation_token = format("%s-efs", var.name)
  encrypted      = true
  kms_key_arn    = module.kms.key_arn

  # File system policy
  attach_policy                             = true
  deny_nonsecure_transport_via_mount_target = false
  bypass_policy_lockout_safety_check        = false
  policy_statements = [
    {
      sid = "Example"
      actions = [
        "elasticfilesystem:ClientRootAccess",
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite"
      ]
      principals = [
        {
          type        = "AWS"
          identifiers = [aws_iam_role.this.arn]
        }
      ]
    }
  ]

  mount_targets         = { for k, v in zipmap(var.azs, var.private_subnet_ids) : k => { subnet_id = v } }
  security_group_vpc_id = var.vpc_id
  security_group_rules = {
    allow_access_from_ec2 = {
      from_port                = 2049
      to_port                  = 2049
      protocol                 = "tcp"
      source_security_group_id = module.ec2_sg.security_group_id
    }
  }

  access_points = {}

  enable_backup_policy = true

  tags = merge(local.tags, { Name = format("%s-efs", var.name) })
}

resource "aws_route53_record" "vpn" {
  for_each = { for k, v in var.vpn_route53_records : k => v }

  zone_id = each.value.zone_id
  name    = try(each.value.name, each.key)
  type    = each.value.type

  alias {
    name                   = aws_lb.vpn.dns_name
    zone_id                = aws_lb.vpn.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "web" {
  for_each = { for k, v in var.console_route53_records : k => v if var.enable_access_console_from_vpn }

  zone_id = each.value.zone_id
  name    = try(each.value.name, each.key)
  type    = each.value.type

  alias {
    name                   = aws_lb.web[0].dns_name
    zone_id                = aws_lb.web[0].zone_id
    evaluate_target_health = true
  }
}
