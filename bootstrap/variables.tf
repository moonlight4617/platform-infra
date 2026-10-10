variable "region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "name_prefix" {
  description = <<-EOT
    全リソース名の接頭辞。S3バケット名はグローバルに一意である必要があるため、
    推測されにくい文字列を含める（例: plat-k3f9d2）。
    ADR-0002により、この値はリポジトリにコミットせず、
    GitHub Secrets / ローカルの local/*.tfvars から渡す。
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{3,30}$", var.name_prefix))
    error_message = "name_prefix は小文字英数字とハイフンのみ、4〜31文字で指定してください。"
  }
}
