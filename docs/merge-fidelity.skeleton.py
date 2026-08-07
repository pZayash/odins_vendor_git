#!/usr/bin/env python3
"""Скелет: аудит сохранности префиксного контента после vendor-merge.

Контракт (агент дописывает под свой проект):
  Вход:  merge-коммит; сравниваем 1-го родителя (ours) с результатом merge
  Prefix: имя/фрагмент путей и строк доработок (пример: PREFIX_)
  Scope:  conf/ (+ расширения, если нужно)
  Exit:  0 чисто / 1 потери при --strict / 2 ошибка

Ось проверки (не путать с vendor-merge-check):
  1) префиксные ФАЙЛЫ (путь содержит prefix): не удалены, не изменены merge'ом;
  2) не-префиксные файлы с префиксными СТРОКАМИ: каждая такая строка из ours
     есть в merge (точное совпадение); счётчик вхождений не упал;
  3) отдельно отчёт по both-side (конфликтным) файлам — auto-resolve мог тихо
     выкинуть блок.

Ограничения:
  - не ловит семантику (вендор сменил сигнатуру, наш вызов со старым именем);
  - модель только для vendor-merge (1-й родитель = наша ветка). На merge двух
    dev-веток «потери» часто = ваши рефакторы, не баг merge.

Запуск:
  python docs/merge-fidelity.skeleton.py HEAD --prefix PREFIX_ --strict
"""

from __future__ import annotations

import argparse
import subprocess
import sys


def git(*args: str) -> str:
    p = subprocess.run(["git", *args], capture_output=True, text=True, encoding="utf-8")
    if p.returncode != 0:
        raise RuntimeError(p.stderr)
    return p.stdout


def parents(commit: str) -> list[str]:
    return git("rev-list", "--parents", "-n", "1", commit).split()[1:]


def ls_tree(rev: str, scope: str) -> set[str]:
    return {
        ln
        for ln in git("ls-tree", "-r", "--name-only", rev).splitlines()
        if ln.startswith(scope)
    }


def show_lines(rev: str, path: str) -> list[str] | None:
    p = subprocess.run(
        ["git", "show", f"{rev}:{path}"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return None if p.returncode != 0 else p.stdout.splitlines()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("commit", nargs="?", default="HEAD")
    ap.add_argument("--prefix", default="PREFIX_")
    ap.add_argument("--scope", default="conf/")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    pars = parents(args.commit)
    if len(pars) < 2:
        print("нужен merge-коммит", file=sys.stderr)
        return 2
    ours = pars[0]

    findings: list[str] = []

    before = {p for p in ls_tree(ours, args.scope) if args.prefix in p}
    after = {p for p in ls_tree(args.commit, args.scope) if args.prefix in p}

    for path in sorted(before - after):
        findings.append(f"PREFIX_DELETED {path}")
    for path in sorted(after - before):
        findings.append(f"PREFIX_ADDED {path}")  # для vendor-merge обычно неожиданно

    # TODO: git diff --name-only ours commit -- <before> чанками (Windows: argv limit)
    # PREFIX_CHANGED если diff непустой

    changed = set(
        git("diff", "--name-only", ours, args.commit, "--", args.scope).splitlines()
    )
    for path in sorted(changed):
        if args.prefix in path:
            continue
        old = show_lines(ours, path)
        new = show_lines(args.commit, path)
        if old is None or new is None:
            continue
        pref_old = [ln for ln in old if args.prefix in ln]
        if not pref_old:
            continue
        new_set = set(new)
        lost = [ln for ln in pref_old if ln not in new_set]
        if lost:
            findings.append(f"LOST_LINES {path} ({len(lost)})")
        c0 = sum(ln.count(args.prefix) for ln in old)
        c1 = sum(ln.count(args.prefix) for ln in new)
        if c1 != c0:
            findings.append(f"COUNT_DIFF {path} {c0}->{c1}")

    # TODO: both-side files = diff base..ours ∩ diff base..vendor — отчёт отдельно

    if not findings:
        print("OK")
        return 0
    print("FINDINGS")
    for line in findings:
        print(line)
    return 1 if args.strict else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as e:
        print(e, file=sys.stderr)
        sys.exit(2)
