# デプロイロールの権限（2/3）: ECS・Lambda・ALB・CloudWatch Logs
#
# 環境分離の手段（ADR-0006）:
#   ECS  : クラスターが環境ごとに分かれているため、service ARN で自然に絞れる
#   Lambda: 関数名が <service>-<app>-<env>-* である前提で絞る
#   ALB  : リスナーが3環境で共有されているため、Environmentタグで絞る

data "aws_iam_policy_document" "deploy_compute" {
  for_each = toset(var.environments)

  # ---------------------------------------------------------------
  # ECS
  # ---------------------------------------------------------------
  statement {
    sid    = "EcsService"
    effect = "Allow"

    actions = [
      "ecs:CreateService",
      "ecs:UpdateService",
      "ecs:DeleteService",
      "ecs:TagResource",
      "ecs:UntagResource",
    ]

    resources = [
      "arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${var.name_prefix}-${each.value}/*",
    ]
  }

  # RegisterTaskDefinition はリソースレベルの制限に対応していないため、
  # リクエストのタグで環境を縛る。
  # アプリ側のモジュールはタスク定義に Environment タグを必ず付ける必要がある
  statement {
    sid    = "EcsRegisterTaskDefinition"
    effect = "Allow"

    actions   = ["ecs:RegisterTaskDefinition"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = [each.value]
    }
  }

  # 命名規約は <service>-<app>-<env>[-suffix]。
  # タスク定義のARNは task-definition/<family>:<revision> なので、
  # 環境名で終わる family（serviceA-appA-dev:3）にも一致させる必要がある。
  # *-<env>-* だけでは一致しない
  statement {
    sid    = "EcsDeregisterTaskDefinition"
    effect = "Allow"

    actions = ["ecs:DeregisterTaskDefinition"]

    resources = [
      "arn:${local.partition}:ecs:${local.region}:${local.account_id}:task-definition/*-${each.value}:*",
      "arn:${local.partition}:ecs:${local.region}:${local.account_id}:task-definition/*-${each.value}-*:*",
    ]
  }

  # ---------------------------------------------------------------
  # Lambda
  # ---------------------------------------------------------------
  statement {
    sid    = "LambdaFunction"
    effect = "Allow"

    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:PublishVersion",
      "lambda:CreateAlias",
      "lambda:UpdateAlias",
      "lambda:DeleteAlias",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:PutFunctionConcurrency",
      "lambda:DeleteFunctionConcurrency",
      "lambda:TagResource",
      "lambda:UntagResource",
    ]

    resources = [
      # 命名規約は <service>-<app>-<env>[-suffix]。
      # 環境名で終わる名前（serviceA-appB-dev）にも一致させる必要がある
      "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:*-${each.value}",
      "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:*-${each.value}-*",
      "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:*-${each.value}:*",
    ]
  }

  # ---------------------------------------------------------------
  # CloudWatch Logs
  # ---------------------------------------------------------------
  statement {
    sid    = "LogGroups"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
    ]

    resources = [
      # ロググループ名が環境名で終わる（/ecs/serviceA-appA-dev）形と、
      # 接尾辞が付く形の両方。*-<env>-* だけでは前者に一致しない
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/ecs/*-${each.value}",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/ecs/*-${each.value}:*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/ecs/*-${each.value}-*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/ecs/*-${each.value}-*:*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/*-${each.value}",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/*-${each.value}:*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/*-${each.value}-*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/*-${each.value}-*:*",
    ]
  }

  # ---------------------------------------------------------------
  # ALB（ADR-0013）
  #
  # ターゲットグループ・ルールの作成時は RequestTag、
  # 変更・削除時は ResourceTag で環境を縛る。
  #
  # 既知の穴: CreateRule のリソースは共有リスナーのARNなので、
  # 「どの環境のルールを作るか」はリクエストタグでしか縛れない。
  # 優先度の衝突は platform-infra 側の採番（locals.tf）で防ぐ。
  # ---------------------------------------------------------------
  statement {
    sid    = "ElbCreateTagged"
    effect = "Allow"

    actions = [
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:AddTags",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = [each.value]
    }
  }

  statement {
    sid    = "ElbModifyOwnEnv"
    effect = "Allow"

    actions = [
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:SetRulePriorities",
      "elasticloadbalancing:RemoveTags",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "elasticloadbalancing:ResourceTag/Environment"
      values   = [each.value]
    }
  }

  # ---------------------------------------------------------------
  # Application Auto Scaling（ECSのオートスケール）
  # ---------------------------------------------------------------
  statement {
    sid    = "AutoScaling"
    effect = "Allow"

    actions = [
      "application-autoscaling:RegisterScalableTarget",
      "application-autoscaling:DeregisterScalableTarget",
      "application-autoscaling:PutScalingPolicy",
      "application-autoscaling:DeleteScalingPolicy",
      "application-autoscaling:TagResource",
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:TagResource",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "deploy_compute" {
  for_each = toset(var.environments)

  name        = "${var.name_prefix}-deploy-compute-${each.value}"
  description = "Deploy (${each.value}): ECS, Lambda, ALB target groups and rules, log groups"
  policy      = data.aws_iam_policy_document.deploy_compute[each.value].json
}

resource "aws_iam_role_policy_attachment" "deploy_compute" {
  for_each = toset(var.environments)

  role       = aws_iam_role.deploy[each.value].name
  policy_arn = aws_iam_policy.deploy_compute[each.value].arn
}
