# デプロイロールの権限（1/3）: state・レポート・成果物・ECR・DynamoDB
#
# ADR-0005の「1回ビルドして昇格」をIAMで強制する:
#   ECRへのpushとartifactsバケットへのPutは dev ロールだけが持つ。
#   stage/prod ロールは読み取りのみ。これにより、stage/prodのパイプラインが
#   新しいイメージを作ることが権限として不可能になる。

data "aws_iam_policy_document" "deploy_storage" {
  for_each = toset(var.environments)

  # terraform refresh / plan に必要な読み取り。
  # 個別の列挙はplanが権限不足で落ちる原因になるため、読み取りは広く許可する
  statement {
    sid    = "ReadForRefresh"
    effect = "Allow"

    actions = [
      "sts:GetCallerIdentity",
      "tag:GetResources",
      "ec2:Describe*",
      "ecs:Describe*",
      "ecs:List*",
      "ecr:Describe*",
      "ecr:List*",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "elasticloadbalancing:Describe*",
      "lambda:Get*",
      "lambda:List*",
      "logs:Describe*",
      "logs:ListTagsForResource",
      "iam:Get*",
      "iam:List*",
      "ssm:DescribeParameters",
      "dynamodb:DescribeTable",
      "s3:ListAllMyBuckets",
      "s3:GetBucketLocation",
      "application-autoscaling:Describe*",
    ]

    resources = ["*"]
  }

  # ---------------------------------------------------------------
  # Terraform state（ADR-0007: <service>/<app>/<env>/terraform.tfstate）
  # ---------------------------------------------------------------
  statement {
    sid    = "StateObjectsForThisEnvOnly"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    # 3階層目が環境名。他環境のstateには触れない
    resources = ["arn:${local.partition}:s3:::${var.name_prefix}-tfstate/*/*/${each.value}/*"]
  }

  statement {
    sid    = "StateBucketList"
    effect = "Allow"

    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.name_prefix}-tfstate"]
  }

  # ---------------------------------------------------------------
  # レポート（ADR-0009）
  # prodはCI時のスキャン結果を参照する必要があるため読み取りも持つ（ADR-0008）
  # ---------------------------------------------------------------
  statement {
    sid    = "Reports"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:PutObjectTagging",
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:AbortMultipartUpload",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.reports.arn,
      "${aws_s3_bucket.reports.arn}/*",
    ]
  }

  statement {
    sid    = "DenyUntaggedReportUpload"
    effect = "Deny"

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reports.arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:RequestObjectTag/Kind"
      values   = ["reports", "logs"]
    }
  }

  # ---------------------------------------------------------------
  # Lambda成果物。読み取りは全環境、書き込みは dev のみ（別ポリシー）
  # ---------------------------------------------------------------
  statement {
    sid    = "ArtifactsRead"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  # ---------------------------------------------------------------
  # ECR。pull と digest の確認のみ。push は dev のみ（別ポリシー）
  # ---------------------------------------------------------------
  statement {
    sid    = "EcrAuth"
    effect = "Allow"

    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # ---------------------------------------------------------------
  # リリース記録（ADR-0010）。
  # 監査記録のため DeleteItem は与えない
  # ---------------------------------------------------------------
  statement {
    sid    = "ReleaseRecords"
    effect = "Allow"

    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:BatchWriteItem",
      "dynamodb:BatchGetItem",
    ]

    resources = [
      aws_dynamodb_table.releases.arn,
      "${aws_dynamodb_table.releases.arn}/index/*",
      aws_dynamodb_table.tickets.arn,
      aws_dynamodb_table.approval_audit.arn,
    ]
  }
}

resource "aws_iam_policy" "deploy_storage" {
  for_each = toset(var.environments)

  name        = "${var.name_prefix}-deploy-storage-${each.value}"
  description = "Deploy (${each.value}): state, reports, artifacts, ECR read, release records"
  policy      = data.aws_iam_policy_document.deploy_storage[each.value].json
}

resource "aws_iam_role_policy_attachment" "deploy_storage" {
  for_each = toset(var.environments)

  role       = aws_iam_role.deploy[each.value].name
  policy_arn = aws_iam_policy.deploy_storage[each.value].arn
}

# ---------------------------------------------------------------------------
# dev ロール限定: 成果物の作成権限
#
# ADR-0005の「1回だけビルドする」を権限として表現している。
# stage/prod のパイプラインはイメージをpushできないため、
# 環境別ビルドが仕組みとして不可能になる。
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_artifact_write" {
  statement {
    sid    = "EcrPush"
    effect = "Allow"

    actions = [
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:TagResource",
    ]

    resources = [for r in aws_ecr_repository.app : r.arn]
  }

  statement {
    sid    = "LambdaArtifactPut"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:PutObjectTagging",
      "s3:AbortMultipartUpload",
    ]

    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

resource "aws_iam_policy" "deploy_artifact_write" {
  name        = "${var.name_prefix}-deploy-artifact-write"
  description = "Build artifacts (ECR push, Lambda zip upload). Attached to the dev role only."
  policy      = data.aws_iam_policy_document.deploy_artifact_write.json
}

resource "aws_iam_role_policy_attachment" "deploy_artifact_write" {
  role       = aws_iam_role.deploy["dev"].name
  policy_arn = aws_iam_policy.deploy_artifact_write.arn
}
