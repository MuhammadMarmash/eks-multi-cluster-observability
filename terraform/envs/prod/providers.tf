###############################################################################
# envs/prod — providers
#
# Both VPCs and both clusters live in one account and one Region, so a single
# provider instance is enough. If observability ever moves to its own AWS
# account (the natural next step for blast-radius isolation), this is where a
# second aliased provider with an assume_role block would go, and the module
# calls would gain `providers = { aws = aws.observability }`.
###############################################################################

provider "aws" {
  region = var.aws_region

  # Guard rail: refuse to run against the wrong account, e.g. a stale
  # AWS_PROFILE pointing at production instead of the lab account.
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = var.repository_url
      CostCenter  = var.cost_center
    }
  }
}
