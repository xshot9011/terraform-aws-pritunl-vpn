variable "vpc_configs" {
  description = "vpc config"
  type        = any
  default = {
    cidr                          = "172.16.0.0/16"
    azs                           = ["ap-southeast-7a", "ap-southeast-7b", "ap-southeast-7c"]
    public_subnets                = ["172.16.0.0/24", "172.16.2.0/24", "172.16.4.0/24"]
    private_subnets               = ["172.16.6.0/24", "172.16.8.0/24", "172.16.10.0/24"]
    enable_nat_gateway            = true
    single_nat_gateway            = true
    enable_flow_log               = true
    flowlog_s3_force_destroy      = true
    flowlog_s3_expiration_in_days = 7
  }
}

variable "enable_access_console_from_public" {
  description = "Whethe to allow connect to console using public connection"
  type        = bool
  default     = true
}

variable "enable_access_console_from_vpn" {
  description = "VPN access console"
  type        = bool
  default     = true
}

variable "route53_hostzone" {
  description = "Hostzone of route53 to be use"
  type        = string
  default     = "therockkkkk.com"
}
