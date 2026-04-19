#!/bin/bash
# fix-case-merge.sh — Исправление регистра имён файлов перед merge на Windows
#
# На NTFS (case-insensitive) git merge падает с ошибкой
# "untracked working tree files would be overwritten by merge"
# когда поставщик изменил регистр букв в имени файла/папки.
#
# Скрипт:
#   1. Сравнивает деревья HEAD и target
#   2. Находит файлы, отличающиеся только регистром
#   3. Исправляет регистр в индексе (update-index --cacheinfo)
#   4. Переименовывает на диске (mv через промежуточное имя)
#   5. Коммитит исправление
#   6. Запускает merge
#
# Использование:
#   ./scripts/fix-case-merge.sh <коммит>
#
# Пример:
#   ./scripts/fix-case-merge.sh 4fa25e0
#
# См. также: docs/ai/merge-vendor-pitfalls.md — Ловушка 4

set -euo pipefail

TARGET="${1:?Использование: $0 <коммит>}"

# Resolve to full hash
TARGET_HASH=$(git rev-parse "$TARGET" 2>/dev/null) || {
    echo "ОШИБКА: коммит не найден: $TARGET"
    exit 1
}

TARGET_SHORT=$(git log --oneline -1 "$TARGET_HASH" 2>/dev/null || echo "$TARGET_HASH")
echo "=== fix-case-merge: HEAD vs $TARGET_SHORT ==="

# --- Шаг 1: Найти case-расхождения ---

echo ""
echo "Сравнение деревьев файлов..."

# Списки файлов
git ls-tree -r HEAD --name-only | sort > /tmp/fcm_head.txt
git ls-tree -r "$TARGET_HASH" --name-only | sort > /tmp/fcm_target.txt

# Файлы только в target (нет exact match в HEAD)
comm -13 /tmp/fcm_head.txt /tmp/fcm_target.txt > /tmp/fcm_only_target.txt

# Lowercase-версии для поиска case-дубликатов
perl -CSD -ne 'print lc' < /tmp/fcm_head.txt | paste - /tmp/fcm_head.txt | sort -t$'\t' -k1,1 > /tmp/fcm_head_lower.tsv
perl -CSD -ne 'print lc' < /tmp/fcm_only_target.txt | paste - /tmp/fcm_only_target.txt | sort -t$'\t' -k1,1 > /tmp/fcm_target_lower.tsv

# Join: lowercase совпадает, но оригинальные имена отличаются
join -t$'\t' -j1 /tmp/fcm_head_lower.tsv /tmp/fcm_target_lower.tsv \
    | awk -F'\t' '$2 != $3 {print $2 "|" $3}' \
    > /tmp/fcm_renames.txt

COUNT=$(wc -l < /tmp/fcm_renames.txt | tr -d ' ')

if [ "$COUNT" -eq 0 ]; then
    echo "Case-расхождений не найдено."
    echo ""
    echo "Запускаю merge..."
    exec git merge "$TARGET_HASH"
fi

echo "Найдено case-расхождений: $COUNT"
echo ""

# --- Шаг 2: Показать что будет сделано ---

echo "Будут исправлены:"
while IFS='|' read -r old new; do
    echo "  $old"
    echo "    -> $new"
done < /tmp/fcm_renames.txt
echo ""

# --- Шаг 3: Исправить индекс ---

echo "Исправление git-индекса..."

while IFS='|' read -r old new; do
    info=$(git ls-files -s "$old" 2>/dev/null)
    if [ -z "$info" ]; then
        echo "  ПРОПУСК (нет в индексе): $old"
        continue
    fi

    mode=$(echo "$info" | awk '{print $1}')
    blob=$(echo "$info" | awk '{print $2}')

    git rm --cached "$old" > /dev/null 2>&1
    git update-index --add --cacheinfo "$mode,$blob,$new"
    echo "  OK: $(basename "$old") -> $(basename "$new")"
done < /tmp/fcm_renames.txt

# --- Шаг 4: Переименовать на диске ---

echo ""
echo "Переименование на диске..."

# Собираем уникальные переименования директорий и файлов.
# Для каждой пары находим первый отличающийся компонент пути —
# это директория (или файл), которую нужно переименовать.
declare -A DISK_RENAMES  # old_path -> new_path (на уровне первого расхождения)

while IFS='|' read -r old new; do
    IFS='/' read -ra OLD_PARTS <<< "$old"
    IFS='/' read -ra NEW_PARTS <<< "$new"

    old_path=""
    new_path=""
    for i in "${!OLD_PARTS[@]}"; do
        if [ "$i" -gt 0 ]; then
            old_path+="/"
            new_path+="/"
        fi
        old_path+="${OLD_PARTS[$i]}"
        new_path+="${NEW_PARTS[$i]}"

        if [ "${OLD_PARTS[$i]}" != "${NEW_PARTS[$i]}" ]; then
            DISK_RENAMES["$old_path"]="$new_path"
            break
        fi
    done
done < /tmp/fcm_renames.txt

# Сортируем по длине пути (короткие первые = верхний уровень первым).
# Переименование директории автоматически переименовывает всё внутри.
SORTED_KEYS=$(for k in "${!DISK_RENAMES[@]}"; do echo "$k"; done | awk '{print length"\t"$0}' | sort -n | cut -f2)

declare -A ALREADY_RENAMED  # отслеживаем уже переименованные родители

while IFS= read -r old_path; do
    [ -z "$old_path" ] && continue
    new_path="${DISK_RENAMES[$old_path]}"

    # Проверяем: не был ли этот путь уже переименован как часть родителя
    skip=false
    for renamed in "${!ALREADY_RENAMED[@]}"; do
        if [[ "$old_path" == "$renamed"/* ]]; then
            skip=true
            break
        fi
    done

    if [ "$skip" = true ]; then
        continue
    fi

    # Определяем актуальный путь (родитель мог быть уже переименован)
    actual_old="$old_path"
    for renamed in "${!ALREADY_RENAMED[@]}"; do
        actual_new="${ALREADY_RENAMED[$renamed]}"
        if [[ "$old_path" == "$renamed"/* ]]; then
            actual_old="${actual_new}${old_path#$renamed}"
            break
        fi
    done

    if [ -e "$actual_old" ]; then
        tmp="${actual_old}_tmp_case_fix_$$"
        mv "$actual_old" "$tmp"
        mv "$tmp" "$new_path"
        ALREADY_RENAMED["$old_path"]="$new_path"
        echo "  OK: $(basename "$old_path") -> $(basename "$new_path")"
    else
        echo "  ПРОПУСК (не найден на диске): $actual_old"
    fi
done <<< "$SORTED_KEYS"

# --- Шаг 5: Коммит ---

echo ""
echo "Коммит исправления регистра..."
git commit -m "Исправление регистра имён файлов для совместимости с обновлением типовой"
echo ""

# --- Шаг 6: Merge ---

echo "=== Запускаю merge $TARGET_SHORT ==="
git merge "$TARGET_HASH"
