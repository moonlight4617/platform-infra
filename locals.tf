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

  # GitHubのOIDCは「不変サブジェクト」が既定で、subにオーナーIDと
  # リポジトリIDが含まれる。
  #
  #   repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:<env>
  #
  # 名前ではなくIDに信頼を結びつけるため、リポジトリを削除して同名で
  # 作り直した場合は信頼関係を明示的に張り直す必要がある。
  # これはセキュリティ上望ましい挙動なので、そのまま受け入れる。
  #
  # repo_id が null のリポジトリ（まだGitHub上に作成していないもの）には
  # AWSへのアクセスを許可しない。
  repo_prefix = {
    for r in var.app_repositories : r.repo =>
    "repo:${var.github_owner}@${var.github_owner_id}/${r.repo}@${r.repo_id}"
    if r.repo_id != null
  }

  platform_repo_prefix = {
    for name, id in var.platform_repo_ids : name =>
    "repo:${var.github_owner}@${var.github_owner_id}/${name}@${id}"
    if id != null
  }

  # 権限を与える対象の接頭辞（アプリ + platform-infra）
  deployable_prefixes = merge(
    local.repo_prefix,
    { for k, v in local.platform_repo_prefix : k => v if k == "platform-infra" },
  )

  # CI（plan・静的解析）用。読み取り専用ロールが引き受ける。
  # platform-cicd / platform-infra 自身のCIも含める
  ci_subjects = [
    for prefix in values(merge(local.repo_prefix, local.platform_repo_prefix)) :
    "${prefix}:environment:ci"
  ]

  # 環境ごとのデプロイ用。
  #   dev  : 成果物のビルド（environment: build）も含む。
  #          ECRへのpushとartifactsへの書き込みを持つのはこのロールだけであり、
  #          ADR-0005「1回だけビルド」を権限として表現している
  #   prod : 緊急リリース経路（environment: prod-emergency）も含む（ADR-0011）
  deploy_subjects = {
    for env in var.environments :
    env => concat(
      [for prefix in values(local.repo_prefix) : "${prefix}:environment:${env}"],
      env == "dev" ? [
        for prefix in values(local.repo_prefix) : "${prefix}:environment:build"
      ] : [],
      env == "prod" ? [
        for prefix in values(local.repo_prefix) : "${prefix}:environment:prod-emergency"
      ] : []
    )
  }

  # platform-infra 自身のデプロイ用。共有リソース（VPC/ALB/IAM）を変更するため、
  # prod と同じ3段承認を通す前提で environment: prod のみを許可する
  platform_subjects = [
    for name, prefix in local.platform_repo_prefix :
    "${prefix}:environment:prod"
    if name == "platform-infra"
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
