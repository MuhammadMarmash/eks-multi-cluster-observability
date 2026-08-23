###############################################################################
# bootstrap — GitHub Actions OIDC and the CI roles
#
# The second chicken-and-egg this module resolves. The pipeline authenticates
# to AWS with a short-lived OIDC token and holds no long-lived key; the role it
# assumes cannot be created BY that pipeline, so it is created here, by a human,
# once, alongside the state bucket.
#
# Three roles, not one, each with the narrowest trust policy that still lets its
# job run:
#
#   ci-plan      read-only, assumable from any ref in this repository
#   ci-apply     privileged, assumable ONLY from a job running in a protected
#                GitHub Environment — the token cannot be minted at all unless a
#                human approved the deployment
#   ci-ecr-push  registry writes, assumable only from main
#
# The environment-scoped trust policy on ci-apply is the important one. It moves
# the approval gate from "GitHub declines to run the job" to "AWS declines to
# issue credentials", which is a control that survives a misconfigured workflow.
###############################################################################

locals {
  github_oidc_enabled = var.github_repository != ""

  owner = split("/", var.github_repository)[0]
  repo  = split("/", var.github_repository)[1]

  github_oidc_url = "https://token.actions.githubusercontent.com"

  # These policies condition on the DEDICATED claims — repository, environment,
  # ref — and never on `sub`.
  #
  # `sub` is the pattern every tutorial reaches for, and it is now a trap.
  # GitHub issues immutable subject claims, so `sub` reads
  #
  #   repo:OWNER@1234567/REPO@7654321:ref:refs/heads/main
  #
  # with numeric IDs interpolated to survive a rename. A policy matching
  # "repo:OWNER/REPO:*" therefore matches nothing, and the only symptom is
  # "Not authorized to perform sts:AssumeRoleWithWebIdentity" with no hint that
  # the claim shape is the problem.
  #
  # The dedicated claims carry no IDs, express the intent directly, and are
  # unaffected by that change.

  ci_roles = local.github_oidc_enabled ? {
    plan = {
      role_name   = "${var.project}-ci-plan"
      description = "GitHub Actions: terraform fmt/validate/plan. Read-only."
      # Any ref, because plans run on pull requests and feature branches.
      # Safe because the role can read but not change anything, except the
      # state lock it must take.
      extra_conditions = {}
      managed_policies = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"]
    }

    apply = {
      role_name   = "${var.project}-ci-apply"
      description = "GitHub Actions: terraform apply. Assumable only from a protected Environment."
      # The `environment` claim is present ONLY when the job declares
      # `environment:`, so a workflow that forgets it cannot obtain this role.
      # Exact names, not a pattern.
      extra_conditions = {
        "environment" = [var.infra_environment_name, var.platform_environment_name]
      }
      # PowerUser covers everything except IAM and Organizations; the IAM half
      # is granted separately below, scoped to the names our modules create.
      managed_policies = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/PowerUserAccess"]
    }

    ecr_push = {
      role_name   = "${var.project}-ci-ecr-push"
      description = "GitHub Actions: mirror third-party charts and images into ECR (ADR 0005)."
      # Main only. scripts/mirror-images.sh is in-tree, so allowing this role
      # from a pull request would let an untrusted branch decide what gets
      # pushed into the registry both clusters pull from.
      extra_conditions = {
        "ref" = ["refs/heads/main"]
      }
      managed_policies = []
    }
  } : {}
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# GitHub rotates this certificate. Reading the thumbprint rather than pinning a
# literal means a rotation does not silently break every pipeline run.
data "tls_certificate" "github" {
  count = local.github_oidc_enabled ? 1 : 0
  url   = local.github_oidc_url
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.github_oidc_enabled ? 1 : 0

  url             = local.github_oidc_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]

  tags = { Name = "github-actions" }
}

###############################################################################
# Roles
###############################################################################

resource "aws_iam_role" "ci" {
  for_each = local.ci_roles

  name        = each.value.role_name
  description = each.value.description

  # Built with jsonencode rather than aws_iam_policy_document for the same
  # reason modules/irsa does: the document stays a plain string this module can
  # expose and a reviewer can read in a plan diff.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRoleWithWebIdentity"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github[0].arn
        }
        Condition = {
          # `repository` pins WHICH repo; `aud` pins that the token was minted
          # for STS. Both are required — `aud` alone would let any GitHub
          # repository on the internet assume this role.
          #
          # Each role then adds the claim that narrows it further: `environment`
          # for apply, `ref` for the registry push.
          # AWS REFUSES a trust policy for a GitHub OIDC principal that does not
          # scope on `sub` or `job_workflow_ref`, so `sub` cannot simply be
          # dropped. It is matched loosely here, with the `@<id>` suffixes
          # wildcarded, and the exact pinning is done by the `repository`
          # StringEquals below — which carries no IDs and cannot be widened by
          # a rename.
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${local.owner}*/${local.repo}*:*"
          }

          StringEquals = merge(
            {
              "token.actions.githubusercontent.com:aud"        = "sts.amazonaws.com"
              "token.actions.githubusercontent.com:repository" = var.github_repository
            },
            {
              for claim, values in each.value.extra_conditions :
              "token.actions.githubusercontent.com:${claim}" => values
            },
          )
        }
      },
    ]
  })

  tags = {
    Name       = each.value.role_name
    Repository = var.github_repository
  }
}

resource "aws_iam_role_policy_attachment" "ci_managed" {
  for_each = merge([
    for k, r in local.ci_roles : {
      for arn in r.managed_policies : "${k}:${basename(arn)}" => { role = k, arn = arn }
    }
  ]...)

  role       = aws_iam_role.ci[each.value.role].name
  policy_arn = each.value.arn
}

###############################################################################
# State backend access
#
# Every role that runs Terraform needs it, including the read-only one: a plan
# takes the `.tflock` lock, which is an S3 write.
###############################################################################

resource "aws_iam_role_policy" "ci_state" {
  for_each = local.github_oidc_enabled ? toset(["plan", "apply"]) : toset([])

  name = "terraform-state-access"
  role = aws_iam_role.ci[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ListStateBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = aws_s3_bucket.state.arn
        },
        {
          Sid    = "ReadWriteStateAndLock"
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            # Releasing the lock is a delete. Without it every run leaves a
            # stale .tflock and the next run blocks.
            "s3:DeleteObject",
          ]
          Resource = "${aws_s3_bucket.state.arn}/*"
        },
      ],
      var.use_customer_managed_key ? [
        {
          Sid      = "UseStateKey"
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = aws_kms_key.state[0].arn
        },
      ] : [],
    )
  })
}

###############################################################################
# IAM, for the apply role only
#
# PowerUserAccess deliberately excludes IAM, and our modules create IAM roles
# for every cluster and every LGTM component. Rather than reaching for
# AdministratorAccess, this grants IAM scoped to the names those modules
# actually use — every one of them is `role-*`.
###############################################################################

resource "aws_iam_role_policy" "ci_apply_iam" {
  count = local.github_oidc_enabled ? 1 : 0

  name = "terraform-iam-access"
  role = aws_iam_role.ci["apply"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageOurRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy",
          # EKS node groups and add-ons hand roles to AWS services.
          "iam:PassRole",
        ]
        # Every role our modules create is named role-*. See modules/eks,
        # modules/irsa and modules/lgtm-storage.
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/role-*"
      },
      {
        Sid    = "ManageClusterOIDCProviders"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
        ]
        # IRSA needs one provider per cluster. Scoped to providers, which
        # cannot be used to escalate on their own.
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/*"
      },
      {
        Sid    = "ReadServiceLinkedRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
          "iam:GetRole",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/*"
      },
    ]
  })
}

###############################################################################
# ECR, for the mirror job
###############################################################################

resource "aws_iam_role_policy" "ci_ecr_push" {
  count = local.github_oidc_enabled ? 1 : 0

  name = "ecr-mirror-push"
  role = aws_iam_role.ci["ecr_push"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetRegistryToken"
        Effect = "Allow"
        # This one cannot be resource-scoped; the API takes no resource.
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "PushMirroredArtifacts"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          # The script skips anything already present, which needs a read.
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        # Repositories in this account only. The job never pushes elsewhere.
        Resource = "arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/*"
      },
    ]
  })
}
