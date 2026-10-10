output "tfstate_bucket" {
  description = "Terraform state用S3バケット名。本体の -backend-config に渡す"
  value       = aws_s3_bucket.tfstate.id
  sensitive   = true
}
