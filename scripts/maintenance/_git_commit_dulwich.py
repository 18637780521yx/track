#!/usr/bin/env python3
"""Commit track changes via dulwich (workaround for git mmap failure on this machine)."""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

from dulwich import porcelain
from dulwich.repo import Repo

ROOT = Path(__file__).resolve().parents[2]

# Deploy / temp helpers — do not commit
EXCLUDE_PREFIXES = (
    "_deploy_",
    "_verify_",
    "_port_check",
    "_purge_once",
    "_track_bundle",
    "_git_commit_",
)
EXCLUDE_NAMES = {
    "_purge_once.py",
    "_track_bundle.tgz",
}


def should_skip(path: str) -> bool:
    name = Path(path).name
    if name in EXCLUDE_NAMES:
        return True
    if name.startswith(EXCLUDE_PREFIXES) or any(name.startswith(p) for p in EXCLUDE_PREFIXES):
        return True
    if name.endswith(".tgz"):
        return True
    if "__pycache__" in path.replace("\\", "/"):
        return True
    return False


def main() -> None:
    os.chdir(ROOT)
    repo = Repo(str(ROOT))

    # Refresh index from HEAD then add paths (dulwich stage)
    status = porcelain.status(repo)
    print("staged", len(status.staged.get("add", [])), len(status.staged.get("modify", [])))
    print("unstaged modified", len(status.unstaged))
    print("untracked", len(status.untracked))

    to_add: list[str] = []
    for p in status.unstaged:
        sp = p.decode() if isinstance(p, bytes) else p
        if not should_skip(sp):
            to_add.append(sp)
    for p in status.untracked:
        sp = p.decode() if isinstance(p, bytes) else p
        if not should_skip(sp):
            to_add.append(sp)

    # also include staged already
    for kind in ("add", "modify", "delete"):
        for p in status.staged.get(kind, []):
            sp = p.decode() if isinstance(p, bytes) else p
            if not should_skip(sp) and sp not in to_add:
                to_add.append(sp)

    to_add = sorted(set(to_add))
    print("adding", len(to_add), "paths:")
    for p in to_add:
        print(" ", p)

    if not to_add:
        print("nothing to commit")
        sys.exit(0)

    porcelain.add(repo, paths=to_add)

    msg = (
        "feat: 测试/线上双环境部署，埋点与报告保留 7 天\n"
        "\n"
        "拆分 track-test(:18765)/track-prod(:28643) 独立栈；服务端定时清理超期 events 与报告衍生数据。\n"
    ).encode()

    author = "冬有雪 <guyuxi@ybm100.com>".encode("utf-8")
    commit_id = porcelain.commit(
        repo,
        message=msg,
        author=author,
        committer=author,
    )
    print("committed", commit_id.decode() if isinstance(commit_id, bytes) else commit_id)

    # show tip
    head = repo.refs[b"HEAD"]
    print("HEAD", head.decode() if isinstance(head, bytes) else head)


if __name__ == "__main__":
    main()
