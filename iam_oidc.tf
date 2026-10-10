# ADR-0006: GitHub ActionsからのAWSアクセスはOIDCのみ。アクセスキーは発行しない。
#
# sub 条件はワイルドカードを使わず、リポジトリ×環境の完全一致で列挙する。
# これにより「prod環境のジョブでなければprodロールを引き受けられない」状態になり、
# 承認ゲート（ADR-0003）を迂回したprodアクセスも防げる。
#
# ロールは5種類:
#   gha-ci           : PRのplanと静的解析。読み取り専用 + レポート書き込み
#   gha-deploy-dev   : dev環境のデプロイ。ECR/artifactsへのpushはここだけが可能
#   gha-deploy-stage : stage環境のデプロイ
#   gha-deploy-prod  : prod環境のデプロイ（prod-emergency を含む）
#   gha-platform     : platform-infra 自身のapply（共有リソース・IAM）

# OIDCプロバイダはアカウントに1つしか作れない。
#
# 実験対象のアカウントには既に存在していた（2024-06作成、client_id_list も
# sts.amazonaws.com で適合）。他の用途で使われている可能性があるため、
# Terraformの管理下には取り込まず参照のみとする。
# 取り込むと、このリポジトリのdestroyが他用途のOIDC連携を壊す。
#
# アカウントに存在しない場合は create_oidc_provider = true で作成する。

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

data "tls_certificate" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]

  tags = {
    Name = "github-actions"
  }
}

# ---------------------------------------------------------------------------
# 信頼ポリシー
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_ci" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # 完全一致の列挙。StringLike は使わない
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.ci_subjects
    }
  }
}

data "aws_iam_policy_document" "assume_deploy" {
  for_each = toset(var.environments)

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.deploy_subjects[each.value]
    }
  }
}

data "aws_iam_policy_document" "assume_platform" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.platform_subjects
    }
  }
}

# ---------------------------------------------------------------------------
# ロール
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ci" {
  name                 = "${var.name_prefix}-gha-ci"
  description          = "GitHub Actions CI (plan and scan, read-only)"
  assume_role_policy   = data.aws_iam_policy_document.assume_ci.json
  max_session_duration = 3600

  tags = {
    Purpose = "ci"
  }
}

resource "aws_iam_role" "deploy" {
  for_each = toset(var.environments)

  name                 = "${var.name_prefix}-gha-deploy-${each.value}"
  description          = "GitHub Actions deploy role for ${each.value}"
  assume_role_policy   = data.aws_iam_policy_document.assume_deploy[each.value].json
  max_session_duration = 3600

  tags = {
    Purpose     = "deploy"
    Environment = each.value
  }
}

resource "aws_iam_role" "platform" {
  name                 = "${var.name_prefix}-gha-platform"
  description          = "GitHub Actions apply role for platform-infra (shared resources, IAM)"
  assume_role_policy   = data.aws_iam_policy_document.assume_platform.json
  max_session_duration = 3600

  tags = {
    Purpose = "platform"
  }
}
