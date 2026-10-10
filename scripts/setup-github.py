#!/usr/bin/env python3
"""GitHub SecretsとEnvironmentsを設定する.

ADR-0002: 機密値はリポジトリに置かず、GitHub Secretsから渡す。
ADR-0003: 承認ゲートはGitHub Environmentsの Required reviewers が正本。

Environmentsの設定はGitHub UI上の状態として存在し、コード管理されない
（ADR-0003の未解決事項）。このスクリプトは
platform-cicd/config/approvers.yaml を正として反映する役割を持つ。
将来的にはTerraformのGitHub providerで宣言的に管理したい。

前提:
    - gh CLI が認証済み
    - terraform output -json github_secrets の結果をファイルで渡す

使い方:
    python3 scripts/setup-github.py --secrets-file secrets.json --apply
    python3 scripts/setup-github.py --secrets-file secrets.json   # dry-run
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys

OWNER = "moonlight4617"

# 全アプリリポジトリに同じSecretsを設定する。
# platform-infra には自身のapply用ロールも渡す
REPOS = ["platform-cicd", "platform-infra", "serviceA-appA"]

# 環境の定義（ADR-0003）
#
# 承認段数を「環境の直列」で表現する。1つの環境に複数の承認者を登録すると
# GitHubの仕様上「誰か1人の承認」で通過してしまい、多段承認にならない。
#
#   reviewers           : 承認者（実験では全ペルソナが同一アカウント）
#   main_only           : mainブランチからのみデプロイを許可する
ENVIRONMENTS: list[dict] = [
    {"name": "ci", "reviewers": False, "main_only": False},
    {"name": "build", "reviewers": False, "main_only": True},
    {"name": "dev", "reviewers": False, "main_only": False},
    {"name": "stage", "reviewers": True, "main_only": True},
    {"name": "prod-approval-1", "reviewers": True, "main_only": True},
    {"name": "prod-approval-2", "reviewers": True, "main_only": True},
    {"name": "prod-approval-3", "reviewers": True, "main_only": True},
    {"name": "prod", "reviewers": False, "main_only": True},
    {"name": "prod-emergency", "reviewers": True, "main_only": True},
]


def gh(args: list[str], check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["gh", *args],
        check=check,
        capture_output=capture,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def current_user_id() -> int:
    res = gh(["api", "user", "--jq", ".id"])
    return int(res.stdout.strip())


def set_secrets(repo: str, secrets: dict[str, str], apply: bool) -> None:
    for name, value in sorted(secrets.items()):
        if not value:
            print(f"    SKIP  {name}（値が空）")
            continue
        if not apply:
            print(f"    (dry) {name}")
            continue
        gh(["secret", "set", name, "--repo", f"{OWNER}/{repo}", "--body", str(value)])
        print(f"    OK    {name}")


def set_environment(repo: str, env: dict, user_id: int, apply: bool) -> None:
    name = env["name"]
    body: dict = {
        "wait_timer": 0,
        # 実験では承認者が1アカウントのため、ONにすると誰も承認できない。
        # 実務では必ず True にする（ADR-0003のトレードオフ）
        "prevent_self_review": False,
        "reviewers": (
            [{"type": "User", "id": user_id}] if env["reviewers"] else []
        ),
        "deployment_branch_policy": (
            {"protected_branches": False, "custom_branch_policies": True}
            if env["main_only"]
            else None
        ),
    }

    label = "承認必須" if env["reviewers"] else "承認なし"
    branch = "main限定" if env["main_only"] else "ブランチ制限なし"

    if not apply:
        print(f"    (dry) {name:<16} {label} / {branch}")
        return

    # --input - で標準入力からJSONを渡す。
    # reviewers や deployment_branch_policy は入れ子構造なので -f では表現できない
    res = subprocess.run(
        [
            "gh",
            "api",
            "--method",
            "PUT",
            f"repos/{OWNER}/{repo}/environments/{name}",
            "--input",
            "-",
        ],
        input=json.dumps(body),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    if res.returncode != 0:
        print(f"    FAIL  {name}: {res.stderr.strip()[:300]}")
        return

    print(f"    OK    {name:<16} {label} / {branch}")

    if env["main_only"]:
        # mainブランチのみを許可する。これによりmain以外からの
        # stage/prodデプロイがGitHub側で不可能になる
        add = subprocess.run(
            [
                "gh",
                "api",
                "--method",
                "POST",
                f"repos/{OWNER}/{repo}/environments/{name}/deployment-branch-policies",
                "-f",
                "name=main",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if add.returncode == 0:
            print(f"          デプロイ元ブランチを main に制限")
        elif "already exists" in (add.stderr or ""):
            print(f"          デプロイ元ブランチの制限は既に設定済み")
        else:
            print(f"          WARN ブランチ制限の設定に失敗: {add.stderr.strip()[:200]}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--secrets-file", required=True)
    ap.add_argument("--apply", action="store_true", help="指定しない場合はdry-run")
    ap.add_argument("--repos", default=",".join(REPOS))
    args = ap.parse_args(argv)

    with open(args.secrets_file, encoding="utf-8-sig") as fh:
        secrets = json.load(fh)

    user_id = current_user_id()
    repos = [r.strip() for r in args.repos.split(",") if r.strip()]

    mode = "適用" if args.apply else "dry-run"
    print(f"モード: {mode} / 対象リポジトリ: {', '.join(repos)}")
    print(f"承認者のユーザーID: {user_id}")
    print()

    for repo in repos:
        print(f"=== {repo} ===")
        print("  Secrets:")
        set_secrets(repo, secrets, args.apply)
        print("  Environments:")
        for env in ENVIRONMENTS:
            set_environment(repo, env, user_id, args.apply)
        print()

    if not args.apply:
        print("dry-runでした。実際に設定するには --apply を付けてください。")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
