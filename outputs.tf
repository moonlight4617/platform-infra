# ADR-0002: ARN・バケット名・アカウントIDはリポジトリに置かない。
# これらは GitHub Secrets に設定する必要があるため output するが、
# すべて sensitive にしてActionsのログに出ないようにする。
#
# 値の取得（ローカルから）:
#   terraform output -json github_secrets | jq
#
# scripts/set-github-secrets.sh でgh CLI経由の登録も行える。

output "github_secrets" {
  description = "各リポジトリのGitHub Secretsに設定する値"
  sensitive   = true

  value = {
    AWS_ACCOUNT_ID        = local.account_id
    AWS_REGION            = local.region
    TFSTATE_BUCKET        = "${var.name_prefix}-tfstate"
    REPORTS_BUCKET        = aws_s3_bucket.reports.id
    ARTIFACTS_BUCKET      = aws_s3_bucket.artifacts.id
    AWS_ROLE_ARN_CI       = aws_iam_role.ci.arn
    AWS_ROLE_ARN_DEV      = aws_iam_role.deploy["dev"].arn
    AWS_ROLE_ARN_STAGE    = aws_iam_role.deploy["stage"].arn
    AWS_ROLE_ARN_PROD     = aws_iam_role.deploy["prod"].arn
    AWS_ROLE_ARN_PLATFORM = aws_iam_role.platform.arn
    # 承認記録専用。デプロイ権限を持たない（FR-25）
    AWS_ROLE_ARN_APPROVAL = aws_iam_role.approval.arn
    RELEASES_TABLE        = aws_dynamodb_table.releases.name
    TICKETS_TABLE         = aws_dynamodb_table.tickets.name
    APPROVAL_AUDIT_TABLE  = aws_dynamodb_table.approval_audit.name
  }
}

output "alb_dns_name" {
  description = "共有ALBのDNS名。動作確認用"
  value       = aws_lb.this.dns_name
}

output "alb_routes" {
  description = "アプリ×環境ごとのパス接頭辞とリスナールール優先度（ADR-0013）"

  value = {
    for key, r in local.alb_routes : key => {
      url      = "http://${aws_lb.this.dns_name}${r.path_prefix}"
      priority = r.priority
    }
  }
}

output "ecr_repository_urls" {
  description = "ECRリポジトリのURL"
  sensitive   = true
  value       = { for name, r in aws_ecr_repository.app : name => r.repository_url }
}
