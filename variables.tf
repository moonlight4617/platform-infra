variable "region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "name_prefix" {
  description = <<-EOT
    全リソース名の接頭辞。bootstrap と同じ値を指定する。
    ADR-0002により、この値はリポジトリにコミットしない。
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{3,30}$", var.name_prefix))
    error_message = "name_prefix は小文字英数字とハイフンのみ、4〜31文字で指定してください。"
  }
}

variable "create_oidc_provider" {
  description = <<-EOT
    GitHubのOIDCプロバイダを作成するか。
    OIDCプロバイダはアカウントに1つしか作れない。既に存在する場合は false にして
    既存のものを参照する（他用途で使われている可能性があるため、
    Terraformの管理下に取り込まない）。

    確認: aws iam list-open-id-connect-providers
  EOT
  type        = bool
  default     = false
}

variable "github_owner" {
  description = "GitHubのオーナー名。OIDCの sub 条件に使う（ADR-0006）"
  type        = string
  default     = "moonlight4617"
}

variable "environments" {
  description = "環境の一覧。並び順がALBリスナールールの優先度の割り当てに影響する"
  type        = list(string)
  default     = ["dev", "stage", "prod"]
}

variable "app_repositories" {
  description = <<-EOT
    このプラットフォームに乗るリポジトリの一覧（ADR-0001）。
    OIDCの信頼ポリシー、ECR、ALBのルール優先度の割り当てに使う。

      repo    : GitHubリポジトリ名
      service : サービス名
      app     : アプリ名（infraリポジトリは null）
      runtime : java / python / typescript / none
      deploy  : ecs / lambda / infra
  EOT
  type = list(object({
    repo    = string
    service = string
    app     = optional(string)
    runtime = string
    deploy  = string
  }))

  default = [
    {
      repo    = "serviceA-infra"
      service = "serviceA"
      app     = null
      runtime = "none"
      deploy  = "infra"
    },
    {
      repo    = "serviceA-appA"
      service = "serviceA"
      app     = "appA"
      runtime = "java"
      deploy  = "ecs"
    },
    {
      repo    = "serviceA-appB"
      service = "serviceA"
      app     = "appB"
      runtime = "python"
      deploy  = "lambda"
    },
    {
      repo    = "serviceA-appC"
      service = "serviceA"
      app     = "appC"
      runtime = "typescript"
      deploy  = "ecs"
    },
  ]

  validation {
    condition = alltrue([
      for r in var.app_repositories : contains(["ecs", "lambda", "infra"], r.deploy)
    ])
    error_message = "deploy は ecs / lambda / infra のいずれかで指定してください。"
  }

  validation {
    condition = alltrue([
      for r in var.app_repositories : r.deploy == "infra" ? r.app == null : r.app != null
    ])
    error_message = "deploy=infra のリポジトリは app を null に、それ以外は app を指定してください。"
  }
}

variable "vpc_cidr" {
  description = "VPCのCIDR"
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "使用するAZ数。ALBは2AZ以上必須"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "ALBは2つ以上のAZを必要とします。"
  }
}

variable "alb_allowed_ingress_cidrs" {
  description = <<-EOT
    ALBへのインバウンドを許可するCIDR。
    ADR-0013によりタスクはパブリックサブネットに置くため、
    実験中は自分のIPに絞ることを推奨する。
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "reports_retention_days" {
  description = "スキャンレポート・planの保持日数（ADR-0009）"
  type        = number
  default     = 400
}

variable "logs_retention_days" {
  description = "CI/CD実行ログの保持日数（ADR-0009）"
  type        = number
  default     = 90
}
