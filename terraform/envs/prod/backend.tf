###############################################################################
# envs/prod — remote state
#
# S3 backend with native state locking; no DynamoDB table exists in this
# platform. Rationale and bucket hardening:
#   docs/adr/0003-s3-native-state-locking.md
#
# The bucket is created by ../../bootstrap. Backend values are passed at init
# time so this file stays account-agnostic:
#   terraform init -backend-config=backend.hcl
###############################################################################

terraform {
  backend "s3" {
    key          = "prod/platform.tfstate"
    encrypt      = true
    use_lockfile = true

    # bucket / region / kms_key_id come from backend.hcl so this file stays
    # account-agnostic and safe to commit.
  }
}
