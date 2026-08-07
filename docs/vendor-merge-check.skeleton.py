#!/usr/bin/env python3
"""Скелет: проверка мерджа с поставщиком по маркерам доработок.

Контракт (агент дописывает под свой проект):
  Вход:  merge-коммит (default HEAD), два родителя: ours=1-й, vendor=2-й
  Scope: каталог выгрузки conf/ (или аналог)
  Маркеры: префикс объектов + маркеры правок в типовом коде (пример: PREFIX, +проект)
  Exit:  0 чисто / 1 найдены потери / 2 ошибка запуска

Ось проверки (не путать с merge-fidelity):
  - файлы с маркерами не удалены merge'ом;
  - счётчик маркеров в изменённых файлах не упал;
  - both-side файлы, взятые целиком как ours → возможна потеря правки вендора (warning).

Не проверяет: семантику BSL, работоспособность форм. Это статика по git.

Запуск после vendor-merge, до выкладки на прод:
  python docs/vendor-merge-check.skeleton.py HEAD
"""

from __future__ import annotations

import argparse
import subprocess
import sys

# --- настрой под проект ---
MARKERS = ["PREFIX_", "+project"]  # пример; замени на свои
SCOPE = "conf/"


def git(*args: str) -> str:
    p = subprocess.run(["git", *args], capture_output=True, text=True, encoding="utf-8")
    if p.returncode != 0:
        print(p.stderr, file=sys.stderr)
        sys.exit(2)
    return p.stdout


def parents(commit: str) -> tuple[str, str]:
    parts = git("rev-list", "--parents", "-n", "1", commit).split()
    if len(parts) < 3:
        print("нужен merge-коммит с двумя родителями", file=sys.stderr)
        sys.exit(2)
    return parts[1], parts[2]  # ours, vendor


def files_with_markers(rev: str) -> set[str]:
    """TODO: git grep -il по MARKERS в rev, ограничить SCOPE.
    Грабля: `git grep <rev>` печатает префикс `<rev>:` — срезать перед сравнением путей.
    """
    raise NotImplementedError


def marker_count(rev: str, path: str) -> int:
    """TODO: число вхождений MARKERS в rev:path (case-insensitive)."""
    raise NotImplementedError


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("commit", nargs="?", default="HEAD")
    args = ap.parse_args()

    ours, vendor = parents(args.commit)
    issues: list[str] = []

    before = files_with_markers(ours)
    after = files_with_markers(args.commit)

    deleted = sorted(p for p in before - after if p.startswith(SCOPE))
    for path in deleted:
        issues.append(f"DELETED_MARKED {path}")

    # файлы, которые менялись ours→merge и всё ещё в after
    changed = set(
        git("diff", "--name-only", ours, args.commit, "--", SCOPE).splitlines()
    )
    for path in sorted(changed & after):
        c0, c1 = marker_count(ours, path), marker_count(args.commit, path)
        if c1 < c0:
            issues.append(f"DECREASED_MARKERS {path} {c0}->{c1}")
        if c0 > 0 and c1 == 0:
            issues.append(f"LOST_MARKERS {path}")

    # TODO (warning): both-side conflict files resolved as OURS → VENDOR_CHANGE_LOST
    _ = vendor

    if issues:
        print("FAIL")
        for line in issues:
            print(line)
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
