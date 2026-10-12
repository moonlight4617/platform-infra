# 承認記録専用ロールの権限（ADR-0003, FR-25）
#
# 承認ゲートのジョブは「承認を受けたこと」を記録するためだけにAWSへアクセスする。
# このロールにできるのは承認監査テーブルへの追記のみで、
# デプロイもリソース変更もできない。
#
# なぜ専用ロールが必要か:
#   承認ジョブは prod-approval-1/2/3 や stage の環境で動く。
#   ここにデプロイ可能なロールを渡すと、
#     - prodロール: prod-approval-1 の段階でprodへデプロイでき、3段承認を迂回できる
#     - stageロール: 承認記録のためにstageへのデプロイ権限を与えることになる
#   どちらも「承認ゲートを迂回したデプロイを権限として不可能にする」（FR-25）
#   という設計に反する。
#
# この穴は実機でprodの3段承認を試して初めて判明した。
# stageでは「たまたまstageロールで動いていた」ため気づけなかった。

data "aws_iam_policy_document" "approval" {
  # 自分が誰かを確認するだけ
  statement {
    sid    = "Identity"
    effect = "Allow"

    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # 承認監査テーブルへの追記のみ。
  # UpdateItem も DeleteItem も与えない（追記専用の監査記録）
  statement {
    sid    = "AppendApprovalAudit"
    effect = "Allow"

    actions = [
      "dynamodb:PutItem",
      "dynamodb:DescribeTable",
    ]

    resources = [aws_dynamodb_table.approval_audit.arn]
  }

  # 念のため、デプロイに使える操作を明示的に拒否する。
  # このロールの用途が広がったときの歯止めになる
  statement {
    sid    = "DenyAnythingDeployable"
    effect = "Deny"

    actions = [
      "ecs:*",
      "lambda:*",
      "elasticloadbalancing:*",
      "ec2:*",
      "iam:*",
      "ecr:*",
      "s3:*",
      "secretsmanager:*",
      "ssm:PutParameter",
      "ssm:DeleteParameter",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "approval" {
  name        = "${var.name_prefix}-approval-audit"
  description = "Append-only access to the approval audit table. Cannot deploy anything."
  policy      = data.aws_iam_policy_document.approval.json
}

resource "aws_iam_role_policy_attachment" "approval" {
  role       = aws_iam_role.approval.name
  policy_arn = aws_iam_policy.approval.arn
}
