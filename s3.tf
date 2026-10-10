# ADR-0009: スキャンレポート・terraform plan・CI/CD実行ログを格納する。
# publicリポジトリではArtifactもActionsログも公開されるため、
# これらは必ずこのprivateバケットにのみ置く。
#
# キー構造:
#   <service>/<app>/<ci|dev|stage|prod>/<commit_sha>/<run_id>/reports/*
#                                                            /terraform/*
#                                                            /logs/*

resource "aws_s3_bucket" "reports" {
  bucket = "${var.name_prefix}-cicd-reports"
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  # ログは短く、レポートとplanは監査サイクルを1周カバーする長さで保持する。
  #
  # ログは <...>/<run_id>/logs/ のように階層の途中に入るため、prefixでは
  # 特定できない。アップロード時にオブジェクトタグ Kind を必ず付与し、
  # タグで判定する（platform-cicd の composite action 側で付与を強制する）。
  # ルールが重複しないよう、両方ともタグ指定にする。
  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {
      tag {
        key   = "Kind"
        value = "logs"
      }
    }

    expiration {
      days = var.logs_retention_days
    }
  }

  rule {
    id     = "expire-reports"
    status = "Enabled"

    filter {
      tag {
        key   = "Kind"
        value = "reports"
      }
    }

    expiration {
      days = var.reports_retention_days
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# Lambdaの成果物（zip）置き場。
# ADR-0005により環境ごとには分けない。1つのzipを3環境で昇格させる。
# キー: <service>/<app>/<commit_sha>.zip
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.name_prefix}-cicd-artifacts"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

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

# ---------------------------------------------------------------------------
# 両バケット共通: HTTPS以外を拒否
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deny_insecure_transport" {
  for_each = {
    reports   = aws_s3_bucket.reports.arn
    artifacts = aws_s3_bucket.artifacts.arn
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      each.value,
      "${each.value}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "reports" {
  bucket = aws_s3_bucket.reports.id
  policy = data.aws_iam_policy_document.deny_insecure_transport["reports"].json

  depends_on = [aws_s3_bucket_public_access_block.reports]
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.deny_insecure_transport["artifacts"].json

  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}
