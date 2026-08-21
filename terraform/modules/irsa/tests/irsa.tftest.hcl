mock_provider "aws" {}

variables {
  role_name          = "role-test-cluster-alb"
  oidc_provider_arn  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE"
  oidc_provider_host = "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE"
  namespace          = "kube-system"
  service_account    = "aws-load-balancer-controller"
}

run "trust_policy_pins_both_sub_and_aud" {
  command = plan

  assert {
    condition     = strcontains(output.assume_role_policy_json, "system:serviceaccount:kube-system:aws-load-balancer-controller")
    error_message = "Trust policy must pin the exact namespace/ServiceAccount in the sub condition."
  }

  assert {
    condition     = strcontains(output.assume_role_policy_json, "sts.amazonaws.com")
    error_message = "Trust policy must pin the aud condition to sts.amazonaws.com; omitting it is the classic IRSA misconfiguration."
  }

  assert {
    condition     = strcontains(output.assume_role_policy_json, "sts:AssumeRoleWithWebIdentity")
    error_message = "Trust policy must allow sts:AssumeRoleWithWebIdentity."
  }
}

run "rejects_wildcard_service_account" {
  command = plan

  variables {
    service_account = "*"
  }

  expect_failures = [var.service_account]
}

run "attaches_every_managed_policy" {
  command = plan

  variables {
    managed_policy_arns = [
      "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
      "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
    ]
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.managed) == 2
    error_message = "One attachment per managed policy ARN."
  }
}

run "inline_policy_is_optional" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.inline) == 0
    error_message = "No inline policy resource when inline_policy_json is null."
  }
}
