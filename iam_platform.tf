# platform-infra 自身のapply用ロール。
#
# VPC・ALB・S3・DynamoDB・ECR・そしてデプロイロール自体（IAM）を作るため、
# 実質的に管理者に近い権限を持つ。これは次の2点で守る:
#   1. 信頼ポリシーが platform-infra リポジトリの environment:prod のみ
#      （= prodの3段承認を通したジョブでしか引き受けられない。ADR-0003）
#   2. 請求・Organizations・アカウント設定は PowerUserAccess の範囲外

resource "aws_iam_role_policy_attachment" "platform_poweruser" {
  role       = aws_iam_role.platform.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "platform_iam" {
  # PowerUserAccess にはIAMの書き込みが含まれないため、必要な範囲を足す
  statement {
    sid    = "ManageRolesAndPolicies"
    effect = "Allow"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:CreateServiceLinkedRole",
      "iam:PassRole",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "ManageOidcProvider"
    effect = "Allow"

    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
    ]

    resources = ["*"]
  }

  # IAMユーザー・アクセスキーは一切作らせない（ADR-0006: OIDCのみ）
  statement {
    sid    = "DenyIamUsersAndKeys"
    effect = "Deny"

    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateAccessKey",
      "iam:AttachUserPolicy",
      "iam:PutUserPolicy",
      "iam:AddUserToGroup",
    ]

    resources = ["*"]
  }

  # 自分自身の信頼ポリシーを書き換えて sub 条件を緩めることを防ぐ
  statement {
    sid    = "DenySelfTrustModification"
    effect = "Deny"

    actions = [
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRole",
    ]

    resources = [aws_iam_role.platform.arn]
  }
}

resource "aws_iam_policy" "platform_iam" {
  name        = "${var.name_prefix}-platform-iam"
  description = "platform-infra: IAM role/policy/OIDC management with guardrails"
  policy      = data.aws_iam_policy_document.platform_iam.json
}

resource "aws_iam_role_policy_attachment" "platform_iam" {
  role       = aws_iam_role.platform.name
  policy_arn = aws_iam_policy.platform_iam.arn
}
