# ADR-0013: ALBは1台を3環境×全ECSアプリで共有し、パスで振り分ける。
#
# ターゲットグループとリスナールールは各アプリリポジトリが作る。
# ここではALB・リスナー・SGと、ルール優先度の採番（locals.tf）までを持つ。
#
# 既知のリスク（ADR-0013に記載）:
#   リスナーが3環境で共有されているため、devの作業でprodのルールを
#   壊す事故が起こりうる。ルールの削除・変更はEnvironmentタグでの
#   制限をIAM側でかける（iam_deploy.tf）。

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Shared ALB for all environments"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-alb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.alb_allowed_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from allowed CIDR"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound to targets"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# アプリのタスクが使うセキュリティグループ。
# ALBからのみ到達でき、タスクはパブリックサブネットにあるが
# 外部から直接到達はできない（ADR-0013）。
#
# 環境ごとに分けることで、IAMのEnvironmentタグ制限と整合させる。
# ---------------------------------------------------------------------------

resource "aws_security_group" "app" {
  for_each = toset(var.environments)

  name        = "${var.name_prefix}-app-${each.value}"
  description = "App tasks for ${each.value}. Inbound from ALB only."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name        = "${var.name_prefix}-app-${each.value}"
    Environment = each.value
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  for_each = toset(var.environments)

  security_group_id            = aws_security_group.app[each.value].id
  description                  = "From shared ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "-1"
}

# ECRからのイメージ取得、SSM/Secrets Managerの参照に必要
resource "aws_vpc_security_group_egress_rule" "app_all" {
  for_each = toset(var.environments)

  security_group_id = aws_security_group.app[each.value].id
  description       = "Allow all outbound (ECR pull, SSM, Secrets Manager)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-shared"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # 実験では誤削除より復旧の容易さを優先する
  enable_deletion_protection = false

  idle_timeout = 60

  tags = {
    Name = "${var.name_prefix}-shared"
  }
}

# ドメインを保有していないためHTTPのみ（ADR-0013）。
# ドメインが使えるようになった時点でHTTPS + ホスト名振り分けへ移行する。
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # どのルールにも一致しない場合。アプリ側がルールを登録するまでここに落ちる
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "No route matched. Check listener rules."
      status_code  = "404"
    }
  }
}
