# ADR-0005: 1回だけビルドして昇格させるため、ECRリポジトリは環境ごとに作らない。
#
# イメージのタグは commit SHA。デプロイ時はタグではなく digest で指定する。
# タグは後から付け替えられるため、digest でなければ同一性が保証されない。

resource "aws_ecr_repository" "app" {
  for_each = toset(local.ecr_repository_names)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = each.value
  }
}

# 未タグのイメージとタグ付きイメージの保持数を制限する。
# タグ付きイメージは、過去のdigestへのロールバック（ADR-0007）に備えて
# 一定数を残す必要がある。
resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 50 tagged images for rollback"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 50
        }
        action = { type = "expire" }
      },
    ]
  })
}
