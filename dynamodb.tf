# ADR-0010: 承認の監査記録、リリース履歴、擬似チケットを保持する。
#
# 承認の「判定」はGitHub Environmentsが正本であり、ここでは行わない。
# ただし「昇格の可否」（同じ成果物がstageで成功済みか）はこのテーブルが正本で、
# prodリリースの事前チェックがここを参照する（ADR-0004）。

resource "aws_dynamodb_table" "releases" {
  name         = "${var.name_prefix}-releases"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "release_id"

  attribute {
    name = "release_id"
    type = "S"
  }

  # GSI用: "<service>#<app>" 形式
  attribute {
    name = "app_key"
    type = "S"
  }

  attribute {
    name = "deployed_at"
    type = "S"
  }

  # 「このアプリの最新リリース」「stage成功済みのdigest一覧」
  # 「事後報告が未完了の緊急リリース」を引くため（ADR-0011）
  global_secondary_index {
    name            = "app-deployed-index"
    hash_key        = "app_key"
    range_key       = "deployed_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  # リリース履歴は監査対象。誤削除を防ぐ
  deletion_protection_enabled = true

  tags = {
    Name = "${var.name_prefix}-releases"
  }
}

resource "aws_dynamodb_table" "tickets" {
  name         = "${var.name_prefix}-tickets"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ticket_id"

  attribute {
    name = "ticket_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  deletion_protection_enabled = true

  tags = {
    Name = "${var.name_prefix}-tickets"
  }
}

# 承認イベントの追記専用テーブル。
# release_id + occurred_at で時系列に並ぶ（承認・却下・タイムアウト）。
resource "aws_dynamodb_table" "approval_audit" {
  name         = "${var.name_prefix}-approval-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "release_id"
  range_key    = "occurred_at"

  attribute {
    name = "release_id"
    type = "S"
  }

  attribute {
    name = "occurred_at"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  deletion_protection_enabled = true

  tags = {
    Name = "${var.name_prefix}-approval-audit"
  }
}
