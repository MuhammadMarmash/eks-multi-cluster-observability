mock_provider "aws" {}

variables {
  zone_name          = "observability.internal"
  primary_vpc_id     = "vpc-0aaaaaaaaaaaaaaaa"
  additional_vpc_ids = ["vpc-0bbbbbbbbbbbbbbbb"]
}

run "creates_a_private_zone_named_as_requested" {
  command = plan

  assert {
    condition     = aws_route53_zone.this.name == "observability.internal"
    error_message = "Zone name must match the requested name exactly."
  }

  assert {
    condition     = length(aws_route53_zone.this.vpc) == 1
    error_message = "Exactly one vpc block belongs on the zone; every other VPC is attached with aws_route53_zone_association."
  }
}

run "associates_every_additional_vpc" {
  command = plan

  assert {
    condition     = length(aws_route53_zone_association.additional) == 1
    error_message = "One association per additional VPC. Without the workload VPC association the gateway name does not resolve from Cluster A at all."
  }
}

run "works_with_no_additional_vpcs" {
  command = plan

  variables {
    additional_vpc_ids = []
  }

  assert {
    condition     = length(aws_route53_zone_association.additional) == 0
    error_message = "An empty additional_vpc_ids list must produce no associations."
  }
}

run "rejects_a_public_looking_zone_name" {
  command = plan

  variables {
    zone_name = "observability.example.com"
  }

  expect_failures = [var.zone_name]
}
