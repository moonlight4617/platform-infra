# platform-infra

共通CI/CD基盤の土台となるAWSリソース。dev/stage/prodの3環境で共有する。

設計判断の背景は [platform-cicd/docs/adr](../platform-cicd/docs/adr/) を参照。

## このリポジトリが持つもの

| 分類 | リソース | 関連ADR |
|---|---|---|
| 認証 | GitHub OIDCプロバイダ、IAMロール5種 | ADR-0006 |
| ネットワーク | VPC、パブリックサブネット×2、共有ALB、SG | ADR-0013 |
| 実行基盤 | ECSクラスター（環境ごと） | ADR-0013 |
| 成果物 | ECRリポジトリ、Lambda用artifactsバケット | ADR-0005 |
| 記録 | レポート用S3、DynamoDB 3テーブル | ADR-0009, ADR-0010 |
| 連携 | SSM Parameter Store（共通資材の出力） | ADR-0014 |

アプリ固有のリソース（ECSサービス、タスク定義、Lambda関数、ターゲットグループ）は
各アプリリポジトリが持つ。

## IAMロール

| ロール | 引き受け条件（OIDC sub） | 用途 |
|---|---|---|
| `<prefix>-gha-ci` | 各リポジトリの `environment:ci` | PRでのplanと静的解析。読み取り専用 + レポート書き込み |
| `<prefix>-gha-deploy-dev` | 各リポジトリの `environment:dev` | dev環境のデプロイ。**ECR/artifactsへの書き込みはここだけ** |
| `<prefix>-gha-deploy-stage` | 各リポジトリの `environment:stage` | stage環境のデプロイ |
| `<prefix>-gha-deploy-prod` | 各リポジトリの `environment:prod` と `environment:prod-emergency` | prod環境のデプロイ |
| `<prefix>-gha-platform` | `platform-infra` の `environment:prod` のみ | このリポジトリのapply |

ADR-0006では「リポジトリ×環境の完全一致」を原則としたが、CIのplanについても
環境を経由させる形に具体化した。`pull_request` を sub 条件に使わず、
`environment: ci` を必ず通すことで、**すべてのAWSアクセス経路が環境で固定される**。

### ADR-0005をIAMで強制している点

`gha-deploy-dev` だけが `ecr:PutImage` と artifactsバケットへの `s3:PutObject` を持つ。
stage/prodのパイプラインはイメージをビルドしてpushできないため、
**環境別ビルドが権限として不可能**になっている。

## 構築手順

### 1. bootstrap（初回のみ）

tfstateを置くS3バケットを作る。ここだけローカルstateで実行する。

```bash
cd bootstrap
terraform init
terraform apply -var="name_prefix=plat-xxxxxx"
terraform output -raw tfstate_bucket   # 次の手順で使う
```

`name_prefix` はS3バケット名に使われるため、グローバルに一意になる値にする。
**この値はリポジトリにコミットしない**（ADR-0002）。

### 2. 本体のapply（初回はローカルから）

OIDCロールがまだ存在しないため、初回は自分の認証情報で実行する。

```bash
cd ..
cp terraform.tfvars.example local/terraform.tfvars
# local/terraform.tfvars を編集（name_prefix と alb_allowed_ingress_cidrs）

terraform init \
  -backend-config="bucket=<bootstrapで出たバケット名>" \
  -backend-config="region=ap-northeast-1"

terraform plan  -var-file=local/terraform.tfvars
terraform apply -var-file=local/terraform.tfvars
```

### 3. GitHub Secretsの登録

```bash
terraform output -json github_secrets | jq
```

出力された値を各リポジトリのSecretsに登録する。
`scripts/set-github-secrets.sh` で gh CLI 経由の一括登録もできる（未作成）。

### 4. GitHub Environmentsの作成

各リポジトリに以下の環境を作る（ADR-0003）。

| 環境 | 承認者 |
|---|---|
| `ci` | なし |
| `dev` | なし |
| `stage` | dev_lead |
| `prod-approval-1` | dev_lead |
| `prod-approval-2` | qa_po |
| `prod-approval-3` | sre |
| `prod` | なし |
| `prod-emergency` | sre |

**「自分のデプロイを自分でレビューさせない」設定はOFFにする。**
承認者が1アカウントのため、ONだと誰も承認できない（ADR-0003のトレードオフ）。

### 構築順序

ADR-0014によりパイプライン上の依存は作っていないが、**初回構築だけは順序が必要**。

```
1. platform-infra   （このリポジトリ。VPC/ALB/ECR/SSM）
2. serviceA-infra   （infraA。SSMへ /serviceA/<env>/* を出力）
3. 各アプリ          （SSMから読む）
```

参照先のSSMパラメータが存在しない場合、アプリ側のplanが失敗することで検知できる。

## 運用上の注意

### CIのplanは `-lock=false` で実行する

stateのロックにS3ネイティブロック（`use_lockfile`）を使っているため、
ロック取得にはS3への書き込みが必要になる。CIロールは読み取り専用なので、
planは必ず `-lock=false` で実行する。

```bash
terraform plan -lock=false -out=tfplan
```

planは状態を変更しないため、ロックなしで問題ない。

### アプリ側のモジュールが守る必要がある規約

IAMポリシーがこれらを前提に権限を絞っているため、守らないとapplyが失敗する。

| 規約 | 理由 |
|---|---|
| リソース名を `<service>-<app>-<env>-*` にする | IAMの名前パターン制限（ADR-0006） |
| 全リソースに `Environment` タグを付ける | IAMのタグ条件とガードレールのdeny |
| **ECSタスク定義の登録時にタグを付ける** | `RegisterTaskDefinition` はリソース制限に非対応のため、`aws:RequestTag` で縛っている |
| ターゲットグループ・リスナールールの作成時にタグを付ける | 同上 |
| IAMロールを `/platform/<env>/` パス配下に作る | IAMのパス制限 |
| S3レポートのアップロード時に `Kind` タグ（`reports` または `logs`）を付ける | ライフサイクルの判定に使う。未付与はdenyされる。terraform planの出力も `reports`（400日保持）を付ける |
| ALBのリスナールール優先度はSSMの値を使う | 自前採番すると3環境で衝突する（ADR-0013） |

### この構成が本番想定でない点

ADR-0013の決定により、**タスクをパブリックサブネットに置いている**。
セキュリティグループでALB経由のみに絞っているが、多層防御になっていない。
実務適用時は必ずプライベートサブネット + VPCエンドポイント（またはNAT）に変更する。

また、ALB 1台を3環境で共有しているため、**リスナールールの変更ミスが全環境に影響する**。
IAMのタグ条件で削除・変更は環境ごとに制限しているが、`CreateRule` は
共有リスナーを対象とするため制限できない。

## 既知の懸念点

実験として意図的に受け入れているもの。実務適用時には対応が必要。

### 1. CIロールの `ReadOnlyAccess`（ADR-0006 の「残したリスク」）

CIロールにはAWS管理の `ReadOnlyAccess` を付けている。**このためPRのCIから
全環境のtfstateファイルをS3経由で読める。prod環境のstateも含まれる。**

- 採用理由: 読み取りアクションを列挙するとplanが権限不足で落ちるリスクが高い
- 緩和: `secretsmanager:GetSecretValue` と `kms:Decrypt` は明示的にDeny。
  SecureStringの復号もstateの書き込みもできない
- 緩和できていない点: state自体の読み取り。PRを作れる人はワークフローを
  書き換えてstateを外部に送り出せる
- 実務での対応: 読み取りアクションの列挙 + stateに機密を置かない設計

**「CIは読み取り専用だから安全」という理解は誤り。**

### 2. リリース記録の書き込み失敗はデプロイ失敗として扱う（ADR-0010 の補足）

DynamoDBへの記録が3回のリトライで失敗した場合、ジョブを失敗させる。
記録のない成功を作らないための判断。

- 懸念: **AWSリソースは更新済みなのにジョブが赤になる**ため、実行者が
  「デプロイは成功したのか」を自分で確認する必要がある
- 懸念: DynamoDBの障害中はprodリリースができない（単一障害点）
- 懸念: 手動で記録を追加する経路を作ると、昇格判定の抜け道になる。
  作る場合は実際にデプロイされたdigestをAWS側から確認してから書き込む作りにする

### 3. ALBの `CreateRule` は環境で制限できない（ADR-0013）

ALB 1台を3環境で共有しているため、`CreateRule` のリソースが共有リスナーになる。
削除・変更は `Environment` タグで縛っているが、作成はリクエストタグでしか縛れない。

**実験用に1つのALBを共有していることから発生する問題であり、
実務でALBを環境ごとに分ければ解消する。今回は対応しない。**

### 4. その他

| 内容 | 現状 |
|---|---|
| Environmentsの設定がコード管理されていない | `platform-cicd/config/approvers.yaml` を正とし、反映は手作業（ADR-0003） |
| SSMパラメータの参照関係を一覧する手段がない | ADR-0014の未解決事項 |
| タスクがパブリックサブネットにある | ADR-0013。実務では必ずプライベートサブネットへ |

## 検証済みの状態（2026-10-02）

| 項目 | 結果 |
|---|---|
| `terraform fmt` | 差分なし |
| `terraform validate`（本体） | Success |
| `terraform validate`（bootstrap） | Success |
| `terraform plan`（bootstrap） | 6 to add, 0 to change, 0 to destroy |
| 本体の `plan` | **未実施**（tfstateバケットが未作成のため） |
| `apply` | **未実施** |

Terraformのバージョンは 1.16.4 で確認。
環境に 1.8.4 も存在し、PATH上はそちらが優先されるため注意
（1.8.4 では `required_version >= 1.10.0` を満たさずエラーになる）。

既存のGitHub OIDCプロバイダを確認済み（2024-06-13作成）。
`create_oidc_provider = false` で既存を参照する設定にしている。
