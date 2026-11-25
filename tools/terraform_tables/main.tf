# S3 Tables' configuration through Terraform's AWS provider (ADR-0126 §5): a table bucket sealed under a KMS key and
# tagged, a namespace, and a tagged table that takes the bucket's encryption. Applied, planned with no change, and
# destroyed by tools/terraform_check.sh, on `serve` (on a cluster a create's settings are set after it, ADR-0126).
# The provider is 6.70.0: `aws_s3tables_table_bucket` has tags since 6.21.0 and an optional encryption since 6.34.0;
# no release has its storage class.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.70.0"
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
  endpoints {
    s3tables = var.endpoint
    sts      = var.endpoint
  }
}

resource "aws_s3tables_table_bucket" "configured" {
  name = "tf-tables"
  encryption_configuration = {
    sse_algorithm = "aws:kms"
    kms_key_arn   = "arn:aws:kms:us-east-1:000000000000:key/orders"
  }
  tags = {
    team = "data"
  }
}

resource "aws_s3tables_namespace" "sales" {
  namespace        = "sales"
  table_bucket_arn = aws_s3tables_table_bucket.configured.arn
}

resource "aws_s3tables_table" "orders" {
  name             = "orders"
  namespace        = aws_s3tables_namespace.sales.namespace
  table_bucket_arn = aws_s3tables_table_bucket.configured.arn
  format           = "ICEBERG"
  tags = {
    stage = "raw"
  }
}

output "bucket_arn" {
  value = aws_s3tables_table_bucket.configured.arn
}

output "table_arn" {
  value = aws_s3tables_table.orders.arn
}
