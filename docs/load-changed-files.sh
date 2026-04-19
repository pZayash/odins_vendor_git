#!/bin/bash

# ==============================================================================
# Скрипт для загрузки измененных файлов конфигурации 1С из git
# ==============================================================================
#
# ОПИСАНИЕ:
#   Автоматически загружает в конфигурацию 1С только те файлы, которые были
#   добавлены или изменены в git-репозитории (исключая удаленные файлы).
#   Значительно ускоряет процесс разработки.
#
# ПЕРВИЧНАЯ НАСТРОЙКА:
#   1. cp .env.example .env
#   2. Настроить пути в .env файле
#   3. Запустить: ./load-changed-files.sh
#
# ТРЕБОВАНИЕ К ИМЕНИ БАЗЫ В СПИСКЕ БАЗ (IBName):
# Скрипт находит запущенный конфигуратор по имени конечного каталога базы
# (последняя папка в пути, например "mybase" из "/F C:/bases/mybase").
# Если конфигуратор открыт из стартера 1С, имя базы в стартере ДОЛЖНО
# совпадать с именем каталога базы.
# Пример: каталог "unf2020.dev.dt" → имя в стартере "unf2020.dev.dt"
#
# НАСТРОЙКИ ПРОЕКТА:
#   Все настройки скриптов проекта хранятся в .env файле.
#   Для получения шаблона: cp .env.example .env
#   Затем отредактируйте .env файл с своими путями.
#
# ИСПОЛЬЗОВАНИЕ:
#   ./load-changed-files.sh [ОПЦИИ]
#
# ПАРАМЕТРЫ:
#   -c, --config-path PATH    Путь к папке conf (по умолчанию: conf)
#   -g, --git-path PATH       Путь к git репозиторию (по умолчанию: .)
#   -o, --output-file FILE    Имя файла со списком файлов (по умолчанию: changed_files.txt)
#   -i, --ib-connection CONN  Строка подключения к ИБ (по умолчанию: /F C:/base/unf2020)
#   -d, --designer-path PATH  Путь к 1cv8.exe
#   -n, --no-close            Не закрывать конфигуратор автоматически
#   -u, --auto-unsupport      Автоматически снимать с поддержки загружаемые объекты
#   -h, --help                Показать эту справку
#
# ФАЙЛЫ НАСТРОЕК:
#   README.md                 Общая документация проекта
#   .env.example              Пример файла настроек (скопируйте в .env)
#   .env                      Файл с настройками (читается автоматически, игнорируется git)
#
# ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ:
#   CONFIG_PATH               Путь к папке conf
#   GIT_PATH                  Путь к git репозиторию
#   IB_CONNECTION             Строка подключения к ИБ
#   DESIGNER_PATH             Путь к 1cv8.exe
#   AUTO_CLOSE_DESIGNER       Автоматически закрывать конфигуратор (true/false, по умолчанию: true)
#   AUTO_UNSUPPORT_OBJECTS    Автоматически снимать с поддержки загружаемые объекты (true/false, по умолчанию: false)
#
# ПРИМЕРЫ:
#   ./load-changed-files.sh                           # Использует настройки из .env
#   ./load-changed-files.sh -c "my_conf" -g "."       # Переопределение через параметры
#   export IB_CONNECTION="/S server/base" && ./load-changed-files.sh  # Через переменные окружения
#   DESIGNER_PATH="/path/to/1cv8.exe" ./load-changed-files.sh         # Переопределение пути
#   ./load-changed-files.sh -n                        # Не закрывать конфигуратор автоматически
#   ./load-changed-files.sh -u                        # Снять с поддержки и загрузить автоматически
#
# АЛГОРИТМ РАБОТЫ:
#   1. Анализ git статуса на наличие добавленных и измененных файлов в conf/ (исключая удаленные)
#   2. Создание списка измененных файлов в UTF-8 файле
#   3. Запуск 1С:Предприятие с командой 1cv8.exe CONFIG /LoadConfigFromFiles -listfile
#
# ==============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[94m'
NC='\033[0m' # No Color

# Функция для логирования
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        "ERROR")
            echo -e "${RED}[$timestamp] ОШИБКА: $message${NC}" >&2
            ;;
        "WARN")
            echo -e "${YELLOW}[$timestamp] ПРЕДУПРЕЖДЕНИЕ: $message${NC}"
            ;;
        "INFO")
            echo "[$timestamp] ИНФО: $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[$timestamp] УСПЕХ: $message${NC}"
            ;;
        *)
            echo "[$timestamp] $message"
            ;;
    esac
}


# Функция для проверки наличия команды
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR" "Команда '$cmd' не найдена. Установите $cmd и добавьте в PATH"
        exit 1
    fi
}

# Запуск Python с fallback на py -3
run_python() {
    if command -v python >/dev/null 2>&1; then
        python "$@"
    elif command -v py >/dev/null 2>&1; then
        py -3 "$@"
    else
        log "ERROR" "Не найден Python (python или py -3). Установите Python и повторите попытку"
        exit 1
    fi
}

# Функция для извлечения имени конечного каталога базы из строки IB_CONNECTION.
# Работает для файловых баз (/F"путь") и серверных (/S сервер\база).
# Пример: /F"C:\bases\кпср_unf2020.dev.dt" → кпср_unf2020.dev.dt
extract_base_dirname() {
    local ib_conn="$1"
    # Убираем кавычки и ключевое слово /F или /S
    local path
    path=$(echo "$ib_conn" | tr -d '"' | sed -E 's|^[[:space:]]*/[FfSs][[:space:]]*||')
    # Берём последний компонент пути (работает с \ и /)
    echo "$path" | sed -E 's|.*[/\\]([^/\\]+)[/\\]?$|\1|' | xargs
}

# Функция для закрытия конкретного конфигуратора 1С по пути к базе
close_1c_designer() {
    log "INFO" "Проверка запущенного конфигуратора для базы: $IB_CONNECTION"

    # Используем имя конечного каталога базы как идентификатор поиска.
    # Это имя присутствует в cmdline в обоих случаях:
    #   - Запуск скриптом:  CONFIG /F"C:\...\кпср_unf2020.dev.dt"
    #   - Запуск из стартера 1С: DESIGNER /IBName "кпср_unf2020.dev.dt"
    # ВАЖНО: имя базы в стартере 1С должно совпадать с именем каталога базы.
    local base_id
    base_id=$(extract_base_dirname "$IB_CONNECTION")
    log "INFO" "Идентификатор базы для поиска: $base_id"

    local designer_pid

    # Ищем процесс: DESIGNER (стартер 1С) или CONFIG (запуск скриптом) + имя каталога базы
    designer_pid=$(powershell.exe -NoProfile -Command "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; Get-CimInstance Win32_Process | Where-Object { \$_.Name -eq '1cv8.exe' -and (\$_.CommandLine -like '*CONFIG*' -or \$_.CommandLine -like '*DESIGNER*') -and \$_.CommandLine -like '*$base_id*' } | Select-Object -ExpandProperty ProcessId" 2>/dev/null | tr -d '\r')

    if [[ -z "$designer_pid" ]]; then
        log "INFO" "Конфигуратор для этой базы не найден или не запущен"
        return 0
    fi

    # Если найдено несколько — берём первый и предупреждаем
    local pid_count
    pid_count=$(echo "$designer_pid" | grep -c .)
    if [[ $pid_count -gt 1 ]]; then
        log "WARN" "Найдено несколько процессов конфигуратора ($pid_count), закрываю первый"
        designer_pid=$(echo "$designer_pid" | head -n 1)
    fi

    log "INFO" "Найден конфигуратор с PID: $designer_pid"
    log "INFO" "Закрытие конфигуратора..."

    # Закрываем конкретный процесс по PID и сохраняем вывод
    # MSYS_NO_PATHCONV=1 отключает автоматическое преобразование путей в Git Bash
    # Используем прямое обращение к taskkill через WinAPI
    MSYS_NO_PATHCONV=1 MSYS_ARG_CONV_EXCL="*" taskkill /F /PID "$designer_pid" > taskkill_output.txt 2>&1
    taskkill_exit_code=$?
    taskkill_output=$(cat taskkill_output.txt 2>/dev/null)
    rm -f taskkill_output.txt

    if [[ $taskkill_exit_code -eq 0 ]]; then
        log "SUCCESS" "Конфигуратор закрыт (PID: $designer_pid)"
        # Небольшая пауза для корректного завершения процесса
        sleep 2
        return 0
    else
        log "ERROR" "Не удалось закрыть конфигуратор (PID: $designer_pid)"
        log "ERROR" "Вывод команды taskkill:"
        echo "$taskkill_output" | while IFS= read -r line; do
            log "ERROR" "  $line"
        done
        return 1
    fi
}

# Функция для преобразования Windows пути в Unix путь
win_to_unix_path() {
    local path="$1"
    # Заменяем обратные слеши на прямые и убираем лишние кавычки
    echo "$path" | sed 's|\\|/|g' | sed 's/^"\(.*\)"$/\1/'
}

# Функция для преобразования Unix пути в Windows путь
unix_to_win_path() {
    local path="$1"
    # Заменяем прямые слеши на обратные для Windows
    echo "$path" | sed 's|/|\\|g'
}

# Загрузка настроек из .env файла
if [[ -f ".env" ]]; then
    log "INFO" "Загрузка настроек из файла .env"
    source ".env"
else
    log "WARN" "Файл .env не найден, используются значения по умолчанию"
fi

# Настройки по умолчанию (если не установлены в .env или переменных окружения)
CONFIG_PATH="${CONFIG_PATH:-conf}"
GIT_PATH="${GIT_PATH:-.}"
OUTPUT_FILE="changed_files.txt"  # Фиксированное имя файла
IB_CONNECTION="${IB_CONNECTION:-"/F\"C:/base/unf2020\""}"
DESIGNER_PATH="${DESIGNER_PATH:-C:/Program Files/1cv8/8.3.27.1786/bin/1cv8.exe}"
AUTO_CLOSE_DESIGNER="${AUTO_CLOSE_DESIGNER:-true}"  # Автоматически закрывать конфигуратор
AUTO_UNSUPPORT_OBJECTS="${AUTO_UNSUPPORT_OBJECTS:-false}"

# Парсинг аргументов командной строки
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config-path)
            CONFIG_PATH="$2"
            shift 2
            ;;
        -g|--git-path)
            GIT_PATH="$2"
            shift 2
            ;;
        -i|--ib-connection)
            IB_CONNECTION="$2"
            shift 2
            ;;
        -d|--designer-path)
            DESIGNER_PATH="$2"
            shift 2
            ;;
        -n|--no-close)
            AUTO_CLOSE_DESIGNER="false"
            shift
            ;;
        -u|--auto-unsupport)
            AUTO_UNSUPPORT_OBJECTS="true"
            shift
            ;;
        -h|--help)
            echo "Использование: $0 [ОПЦИИ]"
            echo ""
            echo "Опции:"
            echo "  -c, --config-path PATH    Путь к папке conf (по умолчанию: conf)"
            echo "  -g, --git-path PATH       Путь к git репозиторию (по умолчанию: .)"
            echo "  -i, --ib-connection CONN  Строка подключения к ИБ (по умолчанию: /F C:/base/unf2020)"
            echo "  -d, --designer-path PATH  Путь к 1cv8.exe (по умолчанию: C:/Program Files/1cv8/8.3.27.1786/bin/1cv8.exe)"
            echo "  -n, --no-close            Не закрывать конфигуратор автоматически"
            echo "  -u, --auto-unsupport      Автоматически снимать с поддержки загружаемые объекты"
            echo "  -h, --help                Показать эту справку"
            echo ""
            echo "Переменные окружения:"
            echo "  CONFIG_PATH               Путь к папке conf"
            echo "  GIT_PATH                  Путь к git репозиторию"
            echo "  IB_CONNECTION             Строка подключения к ИБ"
            echo "  DESIGNER_PATH             Путь к 1cv8.exe"
            echo "  AUTO_UNSUPPORT_OBJECTS    Автоматически снимать с поддержки загружаемые объекты"
            exit 0
            ;;
        *)
            log "ERROR" "Неизвестный параметр: $1"
            echo "Используйте $0 --help для справки"
            exit 1
            ;;
    esac
done

# Начало выполнения
log "INFO" "Начало выполнения скрипта загрузки измененных файлов"

# Проверяем наличие необходимых команд
check_command git

# Преобразуем пути
CONFIG_PATH=$(win_to_unix_path "$CONFIG_PATH")
GIT_PATH=$(win_to_unix_path "$GIT_PATH")

# Переходим в директорию репозитория
if [[ ! -d "$GIT_PATH" ]]; then
    log "ERROR" "Директория git репозитория не найдена: $GIT_PATH"
    exit 1
fi

cd "$GIT_PATH" || {
    log "ERROR" "Не удалось перейти в директорию: $GIT_PATH"
    exit 1
}

log "INFO" "Рабочая директория: $(pwd)"

# Получаем список измененных файлов в папке conf/
log "INFO" "Получение списка измененных файлов из git..."

# Очищаем временные файлы
rm -f temp_changed_files.txt

# Получаем полный путь к репозиторию
repo_path=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$repo_path" ]]; then
    repo_path=$(pwd)
fi

if [[ "$CONFIG_PATH" = /* || "$CONFIG_PATH" =~ ^[A-Za-z]:/ ]]; then
    CONFIG_PATH_ABS="$CONFIG_PATH"
else
    CONFIG_PATH_ABS="$repo_path/$CONFIG_PATH"
fi
CONFIG_PATH_ABS=$(win_to_unix_path "$CONFIG_PATH_ABS")

if [[ ! -d "$CONFIG_PATH_ABS" ]]; then
    log "ERROR" "Папка конфигурации не найдена: $CONFIG_PATH_ABS"
    exit 1
fi

if [[ "$CONFIG_PATH_ABS" != "$repo_path"* ]]; then
    log "ERROR" "Папка конфигурации должна находиться внутри git-репозитория: $CONFIG_PATH_ABS"
    exit 1
fi

CONFIG_GIT_PREFIX="${CONFIG_PATH_ABS#$repo_path/}"
CONFIG_GIT_PREFIX="${CONFIG_GIT_PREFIX#/}"
CONFIG_GIT_PREFIX="${CONFIG_GIT_PREFIX%/}"

# Получаем измененные файлы из разных источников
changed_files=""

# 1. Нестейдженные, staged и untracked файлы внутри CONFIG_PATH
{
    git diff --cached --name-only --diff-filter=ACMR 2>/dev/null
    git diff --name-only --diff-filter=ACMR 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
} | while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    file="${file#./}"
    case "$file" in
        "$CONFIG_GIT_PREFIX"/*)
            relative_path="${file#"$CONFIG_GIT_PREFIX"/}"
            if [[ -n "$relative_path" && -f "$repo_path/$file" ]]; then
                printf '%s\n' "$relative_path"
            fi
            ;;
    esac
done | awk '!seen[$0]++' > temp_changed_files.txt

# 2. Если нет локальных изменений, используем последний коммит
if [[ ! -s temp_changed_files.txt ]]; then
    log "INFO" "Локальных изменений не найдено, проверка последнего коммита..."
    git rev-parse HEAD >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        git diff-tree --no-commit-id --name-only -r --diff-filter=ACMR HEAD 2>/dev/null | while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            case "$file" in
                "$CONFIG_GIT_PREFIX"/*)
                    relative_path="${file#"$CONFIG_GIT_PREFIX"/}"
                    if [[ -n "$relative_path" && -f "$repo_path/$file" ]]; then
                        printf '%s\n' "$relative_path"
                    fi
                    ;;
            esac
        done | awk '!seen[$0]++' > temp_changed_files.txt
    fi
fi

# Проверяем, есть ли измененные файлы
if [[ ! -s temp_changed_files.txt ]]; then
    log "WARN" "Измененных файлов в папке conf/ не найдено"
    rm -f temp_changed_files.txt
    exit 0
fi

# Подсчитываем количество файлов
file_count=$(wc -l < temp_changed_files.txt)
log "INFO" "Найдено $file_count измененных файлов"

# Создаем итоговый файл со списком измененных файлов в UTF-8 with BOM
full_output_file="$repo_path/$OUTPUT_FILE"
{
    printf '\xEF\xBB\xBF'
    cat temp_changed_files.txt
} > "$full_output_file"

# Показываем содержимое файла для проверки
log "INFO" "Содержимое файла $OUTPUT_FILE:"
cat temp_changed_files.txt | while read -r line; do
    log "INFO" "  $line"
done

# Загружаем файлы в конфигурацию 1С
log "INFO" "Загрузка файлов в конфигурацию 1С..."

# Автоматически закрываем конфигуратор перед загрузкой
if [[ "$AUTO_CLOSE_DESIGNER" == "true" ]]; then
    close_1c_designer
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Не удалось закрыть конфигуратор. Выполнение прервано."
        rm -f temp_changed_files.txt
        exit 1
    fi
else
    log "WARN" "Автоматическое закрытие конфигуратора отключено (--no-close)"
    log "WARN" "Закройте конфигуратор вручную перед продолжением"
    read -p "Нажмите Enter для продолжения после закрытия конфигуратора..."
fi

# Preflight по поддержке объектов
PARENT_CONFIG_BIN="$CONFIG_PATH_ABS/Ext/ParentConfigurations.bin"
PARENT_CONFIG_JSON="$repo_path/ParentConfigurations.json"
CONFIG_DUMP_INFO_PATH="$CONFIG_PATH_ABS/ConfigDumpInfo.xml"

if [[ -f "$PARENT_CONFIG_BIN" ]]; then
    PREFLIGHT_ARGS=(
        "scripts/parent_config.py"
        "preflight-load"
        "--config-dir" "$CONFIG_PATH_ABS"
        "--list-file" "$full_output_file"
        "--bin" "$PARENT_CONFIG_BIN"
        "--json" "$PARENT_CONFIG_JSON"
    )

    if [[ -f "$CONFIG_DUMP_INFO_PATH" ]]; then
        PREFLIGHT_ARGS+=("--configdump" "$CONFIG_DUMP_INFO_PATH")
    fi

    if [[ "$AUTO_UNSUPPORT_OBJECTS" == "true" ]]; then
        PREFLIGHT_ARGS+=("--auto-unsupport")
        log "INFO" "Включен режим автоматического снятия с поддержки (--auto-unsupport)"
    fi

    run_python "${PREFLIGHT_ARGS[@]}"
    preflight_exit_code=$?
    if [[ $preflight_exit_code -eq 20 ]]; then
        log "ERROR" "Загрузка остановлена: нужно снять объекты с поддержки или запустить скрипт с --auto-unsupport"
        rm -f temp_changed_files.txt
        exit 20
    elif [[ $preflight_exit_code -ne 0 ]]; then
        log "ERROR" "Preflight по поддержке завершился с ошибкой (код: $preflight_exit_code)"
        rm -f temp_changed_files.txt
        exit $preflight_exit_code
    fi
fi

# Преобразуем пути для Windows командной строки
OUTPUT_FILE_WIN=$(unix_to_win_path "$full_output_file")
CONFIG_PATH_WIN=$(unix_to_win_path "$CONFIG_PATH_ABS")

# Формируем команду загрузки
# Используем частичную загрузку со списком файлов, обновлением ConfigDumpInfo и логом
mkdir -p "$repo_path/.tmp"
LOAD_LOG_FILE="$repo_path/.tmp/load-changed-files.log"
LOAD_LOG_FILE_WIN=$(unix_to_win_path "$LOAD_LOG_FILE")
LOAD_COMMAND="/LoadConfigFromFiles \"$CONFIG_PATH_WIN\" -listFile \"$OUTPUT_FILE_WIN\" -Format Hierarchical -partial -updateConfigDumpInfo /Out \"$LOAD_LOG_FILE_WIN\" /DisableStartupDialogs"

# Полный путь к исполняемому файлу
DESIGNER_PATH=$(unix_to_win_path "$DESIGNER_PATH")
if [[ -f "$DESIGNER_PATH" ]]; then
    DESIGNER_CMD="$DESIGNER_PATH"
else
    log "ERROR" "1С:Предприятие не найден по пути: $DESIGNER_PATH"
    log "ERROR" "Установите 1С:Предприятие или укажите правильный путь через переменную DESIGNER_PATH или опцию -d"
    rm -f temp_changed_files.txt
    exit 1
fi

# Выполняем загрузку
COMMAND="\"$DESIGNER_CMD\" CONFIG $IB_CONNECTION $LOAD_COMMAND"
log "INFO" "Выполнение команды: $COMMAND"
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" eval "$COMMAND"
if [[ $? -ne 0 ]]; then
    log "ERROR" "Не удалось запустить 1С:Предприятие"
    rm -f temp_changed_files.txt
    exit 1
fi

# Запуск конфигуратора в фоне для просмотра результатов загрузки
log "INFO" "Файлы в конфигурацию 1С загружены, запускается конфигуратор для проверки..."
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" eval "\"$DESIGNER_CMD\" CONFIG $IB_CONNECTION" &


# Пауза для просмотра результатов
#read -p "Нажмите Enter для продолжения..."
