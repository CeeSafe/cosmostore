# The IAM resources Terraform's AWS provider makes, against CosmoStore (ADR-0108 §6): applied, planned with no change,
# and destroyed by tools/terraform_check.sh. The account's keys are in the environment (AWS_ACCESS_KEY_ID and
# AWS_SECRET_ACCESS_KEY); the endpoint is a variable.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 5.80.0"
    }
  }
}

variable "endpoint" {
  type = string
}

provider "aws" {
  region                      = "us-east-1"
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = false
  skip_credentials_validation = false
  s3_use_path_style           = true
  endpoints {
    iam = var.endpoint
    sts = var.endpoint
    s3  = var.endpoint
  }
}

locals {
  trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::000000000000:root" }
      Action    = "sts:AssumeRole"
    }]
  })
  writes = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:DeleteObject"]
      Resource = "arn:aws:s3:::tf-bucket/*"
    }]
  })
  lists = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:ListBucket"
      Resource = "arn:aws:s3:::tf-bucket"
    }]
  })
}

resource "aws_iam_user" "dev" {
  name = "tf-dev"
  path = "/tf/"
  tags = { team = "data" }
}

resource "aws_iam_access_key" "dev" {
  user = aws_iam_user.dev.name
}

resource "aws_iam_user_policy" "dev" {
  name   = "lists"
  user   = aws_iam_user.dev.name
  policy = local.lists
}

resource "aws_iam_group" "editors" {
  name = "tf-editors"
  path = "/tf/"
}

resource "aws_iam_group" "readers" {
  name = "tf-readers"
}

resource "aws_iam_group_membership" "editors" {
  name  = "tf-editors-members"
  group = aws_iam_group.editors.name
  users = [aws_iam_user.dev.name]
}

resource "aws_iam_user_group_membership" "dev" {
  user   = aws_iam_user.dev.name
  groups = [aws_iam_group.readers.name]
}

resource "aws_iam_group_policy" "editors" {
  name   = "writes"
  group  = aws_iam_group.editors.id
  policy = local.writes
}

resource "aws_iam_policy" "writers" {
  name        = "tf-writers"
  path        = "/tf/"
  description = "Writes to tf-bucket"
  policy      = local.writes
  tags        = { owner = "ops" }
}

resource "aws_iam_user_policy_attachment" "dev" {
  user       = aws_iam_user.dev.name
  policy_arn = aws_iam_policy.writers.arn
}

resource "aws_iam_group_policy_attachment" "readers" {
  group      = aws_iam_group.readers.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_role" "deployer" {
  name                 = "tf-deployer"
  path                 = "/svc/"
  description          = "Deploys"
  assume_role_policy   = local.trust
  max_session_duration = 7200
  tags                 = { env = "test" }
}

resource "aws_iam_role_policy" "deployer" {
  name   = "lists"
  role   = aws_iam_role.deployer.id
  policy = local.lists
}

resource "aws_iam_role_policy_attachment" "deployer" {
  role       = aws_iam_role.deployer.name
  policy_arn = aws_iam_policy.writers.arn
}

output "key_id" {
  value = aws_iam_access_key.dev.id
}

output "key_secret" {
  value     = aws_iam_access_key.dev.secret
  sensitive = true
}

output "role_arn" {
  value = aws_iam_role.deployer.arn
}
