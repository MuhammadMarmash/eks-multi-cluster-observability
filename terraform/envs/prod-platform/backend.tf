###############################################################################
# envs/prod-platform — remote state
#
# Same bucket as envs/prod, different key. Two states, so a failed Helm release
# can never leave the infrastructure state in a partial condition.
#   docs/adr/0003-s3-native-state-locking.md
#   docs/adr/0008-two-stage-terraform.md
###############################################################################

terraform {
  backend "s3" {
    key          = "prod/kubernetes-platform.tfstate"
    encrypt      = true
    use_lockfile = true

    # bucket / region / kms_key_id come from backend.hcl so this file stays
    # account-agnostic and safe to commit.
  }
}
