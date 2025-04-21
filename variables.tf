variable "name" {
  description = "Naming of resource a&& will be use for prefix as sub resources"
  type        = string
}

variable "tags" {
  description = "Map key:value as for tagging resource under this fukcing module"
  type        = any
  default     = {}
}

variable "vpc_id" {
  description = "VPC ID where to install"
  type        = string
}

variable "default_ec2_policies" {
  description = "Map key:value to attach to ec2's role"
  type        = map(string)
  default = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

variable "additional_profile_policies" {
  description = "Map key:value for policy arn to be attached to ec2's role"
  type        = map(string)
  default     = {}
}

variable "default_ec2_spec" {
  description = "Specification of EC2 that use to run VPN"
  type        = any
  default = {
    ebs_optimized                        = true
    volume_size                          = 20
    default_version                      = null
    update_default_version               = true
    disable_api_termination              = null
    instance_initiated_shutdown_behavior = "stop"
    kernel_id                            = null
    ram_disk_id                          = null
    enable_monitoring                    = true
  }
}

variable "ec2_spec" {
  description = "Specification of EC2 that use to run VPN"
  type        = any
  default     = {}
}

variable "ingress_with_cidr_blocks" {
  description = "Ingress use for VPN traffic"
  type        = any
  default     = []
}

variable "public_subnet_ids" {
  description = "Subnet for NLB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Subnet for vpn instance"
  type        = list(string)
}

variable "enable_access_console_from_vpn" {
  description = "Whether allow vpn to access console from vpn"
  type        = bool
  default     = true
}

variable "nat_public_ips" {
  description = "For allow network under vpn manage console, require if enable_access_console_from_vpn = true"
  type        = list(string)
  default     = []
}

variable "vpn_storage_s3_force_destroy" {
  description = "Allow force destroy on vpn config as s3"
  type        = bool
  default     = false
}

variable "azs" {
  description = "AZ using with EFS mounting"
  type        = list(string)
}

variable "vpn_route53_records" {
  description = "Map of Route53 records to create. Each record map should contain `zone_id`, `name`, and `type`"
  type        = any
  default     = {}
}

variable "console_route53_records" {
  description = "Map of Route53 records to create. Each record map should contain `zone_id`, `name`, and `type`"
  type        = any
  default     = {}
}
