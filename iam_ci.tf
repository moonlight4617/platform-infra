# CIロール: terraform plan と静的解析のみを行う。
#
# 注意（README参照）:
#   use_lockfile を有効にしたstateに対して plan を実行すると、
#   ロックファイルの書き込みが必要になる。CIのplanは状態を変更しないため、
#   必ず `-lock=false` で実行する。このロールには書き込み権限を与えない。

# 実験段階では AWS管理の ReadOnlyAccess を使う。
# 個別にDescribe/List/Getを列挙する方式に比べ、planが権限不足で落ちるリスクが低い。
# トレードオフ: 他環境のstateファイル（S3）も読めてしまう。README の
# 「未解決の論点」に記載。
resource "aws_iam_role_policy_attachment" "ci_readonly" {
  role       = aws_iam_role.ci.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "ci_reports_write" {
  # ADR-0009: planの全文とスキャンレポートはS3にのみ置く。
  # Kind タグの付与を強制し、ライフサイクル（s3.tf）が効くようにする。
  statement {
    sid    = "WriteReports"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:PutObjectTagging",
      "s3:AbortMultipartUpload",
    ]

    resources = ["${aws_s3_bucket.reports.arn}/*"]
  }

  # Kind タグのないアップロードを拒否する。
  # これを忘れるとレポートが無期限に残る、またはログが400日残る
  statement {
    sid    = "DenyUntaggedUpload"
    effect = "Deny"

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reports.arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:RequestObjectTag/Kind"
      values   = ["reports", "logs"]
    }
  }

  # 秘密情報の読み取りは ReadOnlyAccess の範囲外だが、明示的に拒否しておく
  statement {
    sid    = "DenySecretReads"
    effect = "Deny"

    actions = [
      "secretsmanager:GetSecretValue",
      "kms:Decrypt",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "ci_reports_write" {
  name        = "${var.name_prefix}-ci-reports"
  description = "CI: write scan reports and plan output to the reports bucket"
  policy      = data.aws_iam_policy_document.ci_reports_write.json
}

resource "aws_iam_role_policy_attachment" "ci_reports_write" {
  role       = aws_iam_role.ci.name
  policy_arn = aws_iam_policy.ci_reports_write.arn
}
