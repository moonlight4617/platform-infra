# bootstrap: Terraform state を置くS3バケットだけを作る
#
# 鶏と卵の問題（stateバケットをTerraformで作りたいが、stateの置き場所がない）を
# ここだけローカルstateで解決する。一度applyしたら、以降は触らない。
#
# ADR-0002: バケット名は name_prefix として外から渡す。コードに書かない。
# ADR-0007: ロックはS3ネイティブロック（use_lockfile）を使うため、
#           DynamoDBのロックテーブルは作らない。

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  # bootstrap のみローカルstate。terraform.tfstate は .gitignore 済み
  backend "local" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy  = "terraform"
      Repository = "platform-infra"
      Component  = "bootstrap"
    }
  }
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.name_prefix}-tfstate"

  # 誤って消すと全環境のstateを失うため、destroy を禁止する
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# HTTPS以外のアクセスを拒否する
data "aws_iam_policy_document" "tfstate" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate.json

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# 古いバージョンを無期限に残さない
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
