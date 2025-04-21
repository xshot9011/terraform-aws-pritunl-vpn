terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0, < 6.0.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-7"

  default_tags {
    tags = {
      Owner     = "Me"
      Terraform = true
      Workspace = terraform.workspace
    }
  }
}
