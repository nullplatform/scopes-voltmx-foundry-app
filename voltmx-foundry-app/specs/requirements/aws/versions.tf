terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # data.aws_region.current.region needs the v6 attribute.
      version = ">= 6.0"
    }
  }
}
