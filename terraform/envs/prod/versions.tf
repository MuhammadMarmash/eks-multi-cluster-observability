###############################################################################
# envs/prod — provider and Terraform version constraints
###############################################################################

terraform {
  # >= 1.11 is a hard floor: native S3 state locking (`use_lockfile`) landed in
  # 1.10 and the DynamoDB locking arguments are deprecated from 1.11 onwards.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
