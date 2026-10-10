locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  # 新規作成か既存参照か（iam_oidc.tf）
  github_oidc_arn = var.create_oidc_provider ? (
    aws_iam_openid_connect_provider.github[0].arn
    ) : (
    data.aws_iam_openid_connect_provider.github[0].arn
  )

  # ---------------------------------------------------------------------------
  # リポジトリの分類
  # ---------------------------------------------------------------------------

  # ECSで動くアプリ（ALBのターゲットになる）
  ecs_apps = [for r in var.app_repositories : r if r.deploy == "ecs"]

  # Lambdaで動くアプリ（成果物zipをartifactsバケットに置く）
  lambda_apps = [for r in var.app_repositories : r if r.deploy == "lambda"]

  # ECRリポジトリ名。ADR-0005により環境ごとには作らない（1回ビルドして昇格させる）。
  #
  # ECRのリポジトリ名は**小文字のみ**（正規表現
  # [a-z0-9]+((\.|_|__|-+)[a-z0-9]+)* を満たす必要がある）。
  # 命名規約の <service>-<app> は serviceA-appA のように大文字を含むため、
  # ECRに限り小文字化する。
  # 他のリソース（ECS・IAM・ロググループ）は大文字を許容するため変換しない。
  ecr_repository_names = [for a in local.ecs_apps : lower("${a.service}-${a.app}")]

  # ---------------------------------------------------------------------------
  # OIDC の sub 条件（ADR-0006）
  #
  # ワイルドカードを使わず、リポジトリ×環境の完全一致で列挙する。
  # CIのplanも environment: ci を経由させることで、すべての経路を
  # 「環境まで固定された sub」で表現する。
  # ---------------------------------------------------------------------------

  all_repos = [for r in var.app_repositories : r.repo]

  # CI（plan・静的解析）用。読み取り専用ロールが引き受ける。
  # platform-infra 自身のCIもここに含める
  ci_subjects = [
    for repo in concat(local.all_repos, ["platform-infra"]) :
    "repo:${var.github_owner}/${repo}:environment:ci"
  ]

  # 環境ごとのデプロイ用。
  #   dev  : 成果物のビルド（environment: build）も含む。
  #          ECRへのpushとartifactsへの書き込みを持つのはこのロールだけであり、
  #          ADR-0005「1回だけビルド」を権限として表現している
  #   prod : 緊急リリース経路（environment: prod-emergency）も含む（ADR-0011）
  deploy_subjects = {
    for env in var.environments :
    env => concat(
      [for repo in local.all_repos : "repo:${var.github_owner}/${repo}:environment:${env}"],
      env == "dev" ? [
        for repo in local.all_repos : "repo:${var.github_owner}/${repo}:environment:build"
      ] : [],
      env == "prod" ? [
        for repo in local.all_repos : "repo:${var.github_owner}/${repo}:environment:prod-emergency"
      ] : []
    )
  }

  # platform-infra 自身のデプロイ用。共有リソース（VPC/ALB/IAM）を変更するため、
  # prod と同じ3段承認を通す前提で environment: prod のみを許可する
  platform_subjects = [
    "repo:${var.github_owner}/platform-infra:environment:prod",
  ]

  # ---------------------------------------------------------------------------
  # ALB リスナールールの優先度（ADR-0013）
  #
  # ALBは1台を3環境×複数アプリで共有するため、優先度が衝突すると
  # apply が失敗する。採番をアプリ側に任せると必ず衝突するので、
  # ここで一意に割り当ててSSM経由で配布する（ADR-0014）。
  #
  #   priority = 100 + (アプリの並び順 * 10) + (環境の並び順)
  # ---------------------------------------------------------------------------

  env_index = { for i, env in var.environments : env => i }

  alb_routes = merge([
    for i, a in local.ecs_apps : {
      for env in var.environments :
      "${a.service}-${a.app}-${env}" => {
        service     = a.service
        app         = a.app
        env         = env
        path_prefix = "/${env}/${a.app}"
        priority    = 100 + (i * 10) + local.env_index[env]
      }
    }
  ]...)
}
