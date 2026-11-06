#!/usr/bin/env python3
"""Copy the regalia images deployed to dev into the prod overlay.

Used by .github/workflows/regalia-prod-release.yml to prepare the prod release
PR. Only the top-level ``images:`` block of the prod kustomization is
rewritten; the rest of the file is left byte for byte.
"""
import argparse
from pathlib import Path
import re
import sys

import yaml

ROOT = Path(__file__).resolve().parents[2]
OVERLAYS = ROOT / "manifest/base/apps/regalia/workload/overlays"
DEV = OVERLAYS / "openapi-dev"
PROD = OVERLAYS / "openapi-prod"
IMAGES = ("backend", "frontend", "migrations")
REGALIA = "https://github.com/ictsc/ictsc-regalia"
SHA_TAG = re.compile(r"^sha-([0-9a-f]{40})$")


def load_images(overlay: Path) -> dict:
    data = yaml.safe_load((overlay / "kustomization.yaml").read_text())
    return {image["name"]: image for image in data.get("images") or []}


def render_images(images: list) -> str:
    lines = ["images:\n"]
    for image in images:
        lines.append(f"- name: {image['name']}\n")
        for key in ("newName", "newTag", "digest"):
            if image.get(key):
                lines.append(f"  {key}: {image[key]}\n")
    return "".join(lines)


def replace_images_block(text: str, block: str) -> str:
    lines = text.splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if line.rstrip() == "images:"), None)
    if start is None:
        raise SystemExit("prod kustomization has no top-level images: block")
    end = start + 1
    while end < len(lines) and (not lines[end].strip() or lines[end][0] in " -#"):
        end += 1
    return "".join(lines[:start]) + block + "".join(lines[end:])


def commit_of(image: dict | None) -> str | None:
    match = SHA_TAG.match(str((image or {}).get("newTag", "")))
    return match.group(1) if match else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, help="write the PR body here")
    args = parser.parse_args()

    dev = load_images(DEV)
    prod = load_images(PROD)
    missing = [name for name in IMAGES if name not in dev]
    if missing:
        raise SystemExit(f"dev overlay lacks images: {', '.join(missing)}")
    commits = {commit_of(dev[name]) for name in IMAGES}
    if len(commits) != 1 or None in commits:
        # A dev build that is only partly published; the next Image Updater
        # commit completes it and runs this again.
        print("::notice::dev images are not all at one sha-<commit> tag; skipping")
        return 0
    commit = commits.pop()

    # Tags only: sha-<commit> tags are written once by main and never moved.
    merged = [
        {key: dev[name][key] for key in ("name", "newName", "newTag") if key in dev[name]}
        for name in IMAGES
    ] + [image for name, image in prod.items() if name not in IMAGES]
    path = PROD / "kustomization.yaml"
    before = path.read_text()
    after = replace_images_block(before, render_images(merged))
    if yaml.safe_load(after) != {**yaml.safe_load(before), "images": merged}:
        raise SystemExit("rewriting the images block changed other fields")
    path.write_text(after)

    if args.summary:
        previous = commit_of(prod.get("backend"))
        current = (prod.get("backend") or {}).get("newTag", "(none)")
        lines = [
            f"dev で稼働中の regalia [`{commit[:7]}`]({REGALIA}/commit/{commit}) を prod へリリースします。",
            "",
            f"- 現在の prod backend: `{current}`",
            f"- 新しい prod: `sha-{commit}`（{', '.join(IMAGES)}）",
        ]
        if previous:
            lines.append(f"- 差分: {REGALIA}/compare/{previous}...{commit}")
        migrate = (PROD / "migrate.yaml").read_text()
        if "image: migrations" not in migrate:
            lines += [
                "",
                "> [!WARNING]",
                "> prod の migrate Job はまだ migrations イメージを使っていません。"
                "このままマージすると新しい backend に必要なスキーマが適用されないため、"
                "先に `openapi-prod/migrate.yaml` を dev と同じ方式へ移行してください。",
            ]
        lines += [
            "",
            "このPRは `regalia-prod-release` ワークフローが dev の更新ごとに作り直します。"
            "マージすると Argo CD が prod に同期します。",
        ]
        args.summary.write_text("\n".join(lines) + "\n")
    print(f"prod images -> sha-{commit}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
