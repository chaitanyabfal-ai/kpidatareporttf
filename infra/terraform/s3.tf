data "aws_caller_identity" "current" {}

locals {
  bucket_name = coalesce(var.bucket_name, "${data.aws_caller_identity.current.account_id}-ilds-sensor-data")
}

resource "aws_s3_bucket" "ilds" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_versioning" "ilds" {
  bucket = aws_s3_bucket.ilds.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ilds" {
  bucket = aws_s3_bucket.ilds.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Zero-byte marker objects so the prefixes show up as "folders" in the S3
# console. Not required for the pipeline to work (S3 prefixes are virtual),
# purely cosmetic parity with the bash script.
resource "aws_s3_object" "sensor_prefixes" {
  for_each = toset(var.bfa_prefixes)
  bucket   = aws_s3_bucket.ilds.id
  key      = each.value
  content  = ""
}
