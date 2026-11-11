#!/usr/bin/env python3
"""Amend last commit: rebuild from parent + working tree paths (no pulled shots)."""
from __future__ import annotations

import os
import time
from pathlib import Path

from dulwich.objects import Blob, Commit, Tree
from dulwich.repo import Repo

ROOT = Path(__file__).resolve().parents[2]

# Paths that should differ from parent in this feature commit
INCLUDE_NEW_OR_MODIFIED = [
    "README.md",
    "deploy/.env.prod",
    "deploy/.env.test",
    "deploy/README.md",
    "deploy/docker-compose.yml",
    "deploy/nginx.conf",
    "fast_track/README.md",
    "fast_track/lib/src/fast_tracker.dart",
    "fast_track_mcp/README.md",
    "fast_track_mcp/app_sdk/lib/src/agent/mcp_agent.dart",
    "fast_track_mcp/app_sdk/lib/src/gesture/hit_target.dart",
    "fast_track_mcp/app_sdk/lib/src/gesture/manual_gesture_recorder.dart",
    "fast_track_mcp/app_sdk/lib/src/leak/getx_leak_hook.dart",
    "fast_track_mcp/app_sdk/lib/src/leak/transition_ledger.dart",
    "fast_track_mcp/app_sdk/lib/src/lifecycle/app_lifecycle_tracker.dart",
    "fast_track_mcp/app_sdk/lib/src/network/network_capture.dart",
    "fast_track_mcp/docs/INTEGRATION.md",
    "fast_track_mcp/docs/USAGE.md",
    "track-console/src/index.css",
    "track-console/src/pages/PerfReport.tsx",
    "track-console/src/report/buildSessionTimeline.ts",
    "track-server-py/Dockerfile",
    "track-server-py/app/config.py",
    "track-server-py/app/main.py",
    "track-server-py/app/services/retention.py",
    "track-server-py/app/services/sync.py",
]


def upsert_path(repo: Repo, tree: Tree, parts: list[bytes], mode: int, sha: bytes) -> Tree:
    head, *rest = parts
    entries = {e.path: (e.mode, e.sha) for e in tree.items()}
    if not rest:
        entries[head] = (mode, sha)
    else:
        if head in entries and (entries[head][0] & 0o170000) == 0o040000:
            child = repo[entries[head][1]]
        else:
            child = Tree()
        child = upsert_path(repo, child, rest, mode, sha)
        child_sha = repo.object_store.add_object(child)
        entries[head] = (0o040000, child_sha)
    new_tree = Tree()
    for name in sorted(entries.keys()):
        mode_i, sha_i = entries[name]
        new_tree.add(name, mode_i, sha_i)
    return new_tree


def main() -> None:
    repo = Repo(str(ROOT))
    head_commit = repo[repo.head()]
    parent_id = head_commit.parents[0]
    parent = repo[parent_id]
    tree = repo[parent.tree]

    for rel in INCLUDE_NEW_OR_MODIFIED:
        path = ROOT / rel
        if not path.is_file():
            print("missing", rel)
            continue
        data = path.read_bytes()
        blob = Blob.from_string(data)
        sha = repo.object_store.add_object(blob)
        tree = upsert_path(repo, tree, rel.encode().split(b"/"), 0o100644, sha)
        print("upsert", rel)

    tree_id = repo.object_store.add_object(tree)
    author = head_commit.author
    now = int(time.time())
    msg = (
        "feat: 测试/线上双环境部署，埋点与报告保留 7 天\n"
        "\n"
        "拆分 track-test(:18765)/track-prod(:28643) 独立栈；"
        "服务端定时清理超期 events 与报告衍生数据。\n"
    ).encode("utf-8")

    new_commit = Commit()
    new_commit.tree = tree_id
    new_commit.parents = [parent_id]
    new_commit.author = author
    new_commit.committer = author
    new_commit.author_time = now
    new_commit.commit_time = now
    new_commit.author_timezone = 8 * 3600
    new_commit.commit_timezone = 8 * 3600
    new_commit.message = msg
    cid = repo.object_store.add_object(new_commit)
    repo.refs[b"refs/heads/main"] = cid
    repo.refs.set_symbolic_ref(b"HEAD", b"refs/heads/main")

    # verify no pulled
    def has_pulled(tree_id, prefix=b"") -> bool:
        t = repo[tree_id]
        for e in t.items():
            path = prefix + e.path
            if b"reports/pulled" in path:
                return True
            if (e.mode & 0o170000) == 0o040000:
                if has_pulled(e.sha, path + b"/"):
                    return True
        return False

    print("amended", cid.hex())
    print("parent", parent_id.hex())
    print("has_pulled", has_pulled(tree_id))


if __name__ == "__main__":
    main()
