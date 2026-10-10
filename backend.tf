# ADR-0002: バケット名をコードに書かないため partial configuration にする
#
#   terraform init \
#     -backend-config="bucket=${TFSTATE_BUCKET}" \
#     -backend-config="region=${AWS_REGION}"
#
# key は固定。platform-infra は環境共有のリソースを持つため、
# アプリのstate（<service>/<app>/<env>/terraform.tfstate）とは別系統に置く。

terraform {
  backend "s3" {
    key          = "platform/infra/shared/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
