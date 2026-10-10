# ADR-0014: 共通資材の値はSSM Parameter Storeに出力し、
# アプリ側のTerraformは data "aws_ssm_parameter" で読む。
# terraform_remote_state は使わない。
#
# 命名規約:
#   /platform/<env>/<key>                       プラットフォーム共通
#   /platform/<env>/<service>-<app>/<key>       アプリ別の割り当て値
#
# 1アカウント構成（ADR-0006）のため、VPCやALBは3環境で同じ値になる。
# それでも環境ごとのパスに書くのは、将来アカウントを分けたときに
# 読み取り側（アプリ）を変更せずに済むようにするため。

locals {
  platform_params = merge([
    for env in var.environments : {
      "${env}/vpc_id"                = aws_vpc.this.id
      "${env}/app_subnet_ids"        = join(",", aws_subnet.public[*].id)
      "${env}/app_security_group_id" = aws_security_group.app[env].id
      "${env}/alb_arn"               = aws_lb.this.arn
      "${env}/alb_listener_arn"      = aws_lb_listener.http.arn
      "${env}/alb_dns_name"          = aws_lb.this.dns_name
      "${env}/alb_zone_id"           = aws_lb.this.zone_id
      "${env}/ecs_cluster_name"      = aws_ecs_cluster.this[env].name
      "${env}/ecs_cluster_arn"       = aws_ecs_cluster.this[env].arn
      "${env}/reports_bucket"        = aws_s3_bucket.reports.id
      "${env}/artifacts_bucket"      = aws_s3_bucket.artifacts.id
      "${env}/releases_table"        = aws_dynamodb_table.releases.name
      "${env}/tickets_table"         = aws_dynamodb_table.tickets.name
      "${env}/approval_audit_table"  = aws_dynamodb_table.approval_audit.name
    }
  ]...)

  # ALBのルート情報。優先度の採番は platform-infra が持つ（locals.tf）
  app_route_params = merge([
    for key, r in local.alb_routes : {
      "${r.env}/${r.service}-${r.app}/path_prefix"            = r.path_prefix
      "${r.env}/${r.service}-${r.app}/listener_rule_priority" = tostring(r.priority)
      # ECRは小文字のみ許可されるため、キーも小文字化したものを使う
      "${r.env}/${r.service}-${r.app}/ecr_repository_url"  = aws_ecr_repository.app[lower("${r.service}-${r.app}")].repository_url
      "${r.env}/${r.service}-${r.app}/ecr_repository_name" = aws_ecr_repository.app[lower("${r.service}-${r.app}")].name
    }
  ]...)
}

resource "aws_ssm_parameter" "platform" {
  for_each = local.platform_params

  name  = "/platform/${each.key}"
  type  = "String"
  value = each.value
  tier  = "Standard"

  tags = {
    Environment = split("/", each.key)[0]
  }
}

resource "aws_ssm_parameter" "app_route" {
  for_each = local.app_route_params

  name  = "/platform/${each.key}"
  type  = "String"
  value = each.value
  tier  = "Standard"

  tags = {
    Environment = split("/", each.key)[0]
  }
}
