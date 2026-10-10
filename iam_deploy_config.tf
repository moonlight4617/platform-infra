# デプロイロールの権限（3/3）: IAM・SSM・Secrets Manager とガードレール
#
# アプリは自分のタスクロール/実行ロールを作る必要があるため、IAMの権限を持つ。
# 権限昇格を防ぐため、次の3点で縛る:
#   1. 操作対象を /platform/<env>/ パス配下のロール・ポリシーに限定する
#   2. アタッチできるポリシーを AWS管理のservice-roleと自パス配下に限定する
#      （AdministratorAccess のアタッチを防ぐ）
#   3. PassRole の渡し先サービスを限定する

data "aws_iam_policy_document" "deploy_config" {
  for_each = toset(var.environments)

  statement {
    sid    = "ManageOwnPathRoles"
    effect = "Allow"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]

    resources = ["arn:${local.partition}:iam::${local.account_id}:role/platform/${each.value}/*"]
  }

  # AdministratorAccess などをアタッチできないようにする
  statement {
    sid    = "AttachLimitedPolicies"
    effect = "Allow"

    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]

    resources = ["arn:${local.partition}:iam::${local.account_id}:role/platform/${each.value}/*"]

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"

      values = [
        "arn:${local.partition}:iam::aws:policy/service-role/*",
        "arn:${local.partition}:iam::${local.account_id}:policy/platform/${each.value}/*",
      ]
    }
  }

  statement {
    sid    = "ManageOwnPathPolicies"
    effect = "Allow"

    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]

    resources = ["arn:${local.partition}:iam::${local.account_id}:policy/platform/${each.value}/*"]
  }

  statement {
    sid    = "PassRoleToRuntimeServices"
    effect = "Allow"

    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/platform/${each.value}/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"

      values = [
        "ecs-tasks.amazonaws.com",
        "lambda.amazonaws.com",
        "events.amazonaws.com",
        "application-autoscaling.amazonaws.com",
      ]
    }
  }

  # ---------------------------------------------------------------
  # SSM Parameter Store（ADR-0014）
  #
  # 読み取り: /platform/<env>/* と /<service>/<env>/*
  # 書き込み: /<service>/<env>/* のみ。
  #           /platform/* は platform-infra の出力なので書かせない
  # ---------------------------------------------------------------
  statement {
    sid    = "ReadPlatformAndServiceParams"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:ListTagsForResource",
    ]

    resources = [
      "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/platform/${each.value}/*",
      "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/*/${each.value}/*",
    ]
  }

  statement {
    sid    = "WriteServiceParams"
    effect = "Allow"

    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:LabelParameterVersion",
    ]

    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/*/${each.value}/*"]
  }

  statement {
    sid    = "DenyWritingPlatformParams"
    effect = "Deny"

    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
    ]

    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/platform/*"]
  }

  # ---------------------------------------------------------------
  # Secrets Manager
  # ---------------------------------------------------------------
  statement {
    sid    = "ManageOwnEnvSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:UpdateSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:DeleteSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:ListSecretVersionIds",
    ]

    resources = ["arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:*-${each.value}-*"]
  }

  # ---------------------------------------------------------------
  # ガードレール: Environmentタグが自環境と異なるリソースへの変更を拒否する
  #
  # タグが存在しないリソースは対象外（Null条件）。
  # 未タグのリソースは、各Allow文のリソースパターンで既に制限されている。
  # ---------------------------------------------------------------
  statement {
    sid    = "DenyCrossEnvironmentMutation"
    effect = "Deny"

    actions = [
      "ecs:UpdateService",
      "ecs:DeleteService",
      # リソースレベル権限に非対応のため `*` で許可している（iam_deploy_compute.tf）。
      # 環境の制限はこのタグ条件が担う
      "ecs:DeregisterTaskDefinition",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:DeleteFunction",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:DeleteTargetGroup",
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "secretsmanager:PutSecretValue",
      "secretsmanager:DeleteSecret",
    ]

    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [each.value]
    }

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/Environment"
      values   = ["false"]
    }
  }

  # 共有リソース（VPC・ALB本体・ECRリポジトリ・DynamoDBテーブル）の
  # 削除・変更は platform-infra の役割。デプロイロールには持たせない
  statement {
    sid    = "DenySharedResourceMutation"
    effect = "Deny"

    actions = [
      "ec2:DeleteVpc",
      "ec2:DeleteSubnet",
      "ec2:DeleteInternetGateway",
      "ec2:DeleteRouteTable",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:ModifyListener",
      "ecr:DeleteRepository",
      "ecr:PutLifecyclePolicy",
      "dynamodb:DeleteTable",
      "dynamodb:UpdateTable",
      "ecs:DeleteCluster",
      "iam:CreateOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:DeleteOpenIDConnectProvider",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "deploy_config" {
  for_each = toset(var.environments)

  name        = "${var.name_prefix}-deploy-config-${each.value}"
  description = "Deploy (${each.value}): scoped IAM, SSM, Secrets Manager, plus guardrails"
  policy      = data.aws_iam_policy_document.deploy_config[each.value].json
}

resource "aws_iam_role_policy_attachment" "deploy_config" {
  for_each = toset(var.environments)

  role       = aws_iam_role.deploy[each.value].name
  policy_arn = aws_iam_policy.deploy_config[each.value].arn
}
