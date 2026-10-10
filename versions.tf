terraform {
  # S3ネイティブロック（use_lockfile）を使うため 1.10 以上（ADR-0007）
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
