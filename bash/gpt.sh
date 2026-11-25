#!/bin/bash

# Перехватываем Ctrl+C (сигнал SIGINT) для красивого выхода при вводе текста
trap 'echo -e "\nВвод прерван."; exit 130' INT

# ==============================================================
# USAGE:
# gpt [-s "Системный промпт"] [-m] "ваш запрос"
# gpt -h
#
#   -s  Использовать кастомный системный промпт вместо стандартного.
#       Пример: gpt -s "Ты — Senior Python Developer" "Напиши код"
#   -m  Продолжить диалог текущей сессии оболочки (до 10 пар вопрос-ответ).
#       Без -m история начинается заново.
#   -h  Показать справку.
#
# Запрос можно передать через stdin:
#   journalctl -p err -n 50 | gpt "Проанализируй ошибки"
# Если запрос передан и аргументом, и через stdin, содержимое stdin
# добавляется к запросу отдельным блоком.
#
# Ответ печатается по мере генерации. История -m живёт в рамках сессии
# оболочки (~/.local/gigachat_history_<pid>). Файлы завершённых сессий
# удаляются при следующем запуске gpt.
#
# Настройки через переменные окружения:
#   GIGACHAT_CREDENTIALS  ключ авторизации (обязательно)
#   GIGACHAT_MODEL        модель (по умолчанию GigaChat-2-Pro)
#   GIGACHAT_TIMEOUT      таймаут запроса в секундах (по умолчанию 120)
#   GIGACHAT_BASE_URL     адрес API (по умолчанию https://api.giga.chat)
# ==============================================================
# INSTALL:
# cp gpt.sh /usr/local/bin/gpt
# chmod +x /usr/local/bin/gpt
# ==============================================================

# Кеш токена содержит действующий секрет — не даём читать его другим пользователям.
umask 077

BASE_URL="${GIGACHAT_BASE_URL:-https://api.giga.chat}"
OAUTH_URL="https://ngw.devices.sberbank.ru:9443/api/v2/oauth"
MODEL="${GIGACHAT_MODEL:-GigaChat-2-Pro}"
HTTP_TIMEOUT="${GIGACHAT_TIMEOUT:-120}"

TOKEN_TTL=1500
MAX_HISTORY_PAIRS=10

CACHE_DIR="$HOME/.local"
TOKEN_CACHE="$CACHE_DIR/gigachat_token"

# История привязана к родительской оболочке: $PPID одинаков у всех вызовов
# из одной сессии. Каталог личный, поэтому чужих файлов здесь не бывает.
HIST_DIR="$CACHE_DIR"
HISTORY_FILE="$HIST_DIR/gigachat_history_$PPID"

# Разбор потока SSE: data: {...} -> текст дельты.
SSE_FILTER='select(startswith("data: ")) | ltrimstr("data: ") | fromjson? | .choices[0].delta.content? // empty'

# Временные файлы запуска (конфиги curl, тело запроса, ответ, заголовки)
# лежат в отдельном каталоге и удаляются при любом выходе.
TMP_DIR=""
# Временные файлы для атомарной замены кэша/истории лежат рядом с ними.
TMP_FILES=()

cleanup() {
    [ ${#TMP_FILES[@]} -eq 0 ] || rm -f "${TMP_FILES[@]}"
    [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
    return 0
}
trap cleanup EXIT

make_tmp() {
    local file
    [ -n "$TMP_DIR" ] || return 1
    file=$(mktemp "$TMP_DIR/tmp.XXXXXX") || return 1
    printf '%s\n' "$file"
}

# Экранирование значения для конфигурационного файла curl.
curl_escape() {
    printf '%s' "$1" | sed 's/[\\"]/\\&/g'
}

print_usage() {
    echo "Использование: $0 [-s \"Системный промпт\"] [-m] \"ваш запрос\""
    echo "  -s  Кастомный системный промпт."
    echo "  -m  Продолжить диалог текущей сессии."
    echo "  -h  Показать справку."
    exit "$1"
}

# Удаляем историю завершённых сессий при следующем запуске:
# файл брошен, если его оболочки уже нет.
prune_history() {
    local file pid

    [ -d "$HIST_DIR" ] || return 0

    for file in "$HIST_DIR"/gigachat_history_*; do
        # Только обычные файлы, не симлинки и не чужие файлы.
        [ -f "$file" ] || continue
        [ -L "$file" ] && continue
        [ -O "$file" ] || continue
        pid=${file##*_}

        # Ожидаемое имя: gigachat_history_<число>. Нечисловые суффиксы
        # могут принадлежать пользовательским файлам — их не трогаем.
        case "$pid" in
            '' | *[!0-9]*) continue ;;
        esac

        [ "$pid" = "$PPID" ] && continue
        kill -0 "$pid" 2>/dev/null || rm -f "$file"
    done
}

# Печатает историю диалога как JSON-массив сообщений.
# Симлинк или чужой файл игнорируются: имя в ~/.local предсказуемо.
load_history() {
    if [ -f "$HISTORY_FILE" ] && [ ! -L "$HISTORY_FILE" ] && [ -O "$HISTORY_FILE" ]; then
        jq -c 'if type == "array" then . else [] end' "$HISTORY_FILE" 2>/dev/null && return 0
    fi
    printf '[]\n'
}

# История перезаписывается целиком: контекст отправленного запроса + новый обмен.
# Большие вопрос и ответ передаются в jq через файлы (--rawfile), а не аргументами.
save_history() {
    local history=$1 user=$2 assistant=$3
    local tmp err_tmp user_tmp assistant_tmp

    tmp=$(mktemp "$HIST_DIR/.gigachat_history_${PPID}.XXXXXX" 2>/dev/null) || {
        echo "Предупреждение: не удалось создать временный файл истории." >&2
        return 1
    }
    TMP_FILES+=("$tmp")

    user_tmp=$(make_tmp) || {
        echo "Предупреждение: не удалось создать временный файл истории." >&2
        return 1
    }
    assistant_tmp=$(make_tmp) || {
        echo "Предупреждение: не удалось создать временный файл истории." >&2
        return 1
    }
    err_tmp=$(make_tmp) || err_tmp=/dev/null

    if ! printf '%s' "$user" > "$user_tmp"; then
        echo "Предупреждение: не удалось сохранить историю диалога." >&2
        return 1
    fi
    if ! printf '%s' "$assistant" > "$assistant_tmp"; then
        echo "Предупреждение: не удалось сохранить историю диалога." >&2
        return 1
    fi

    if printf '%s' "$history" | jq -c \
        --rawfile u "$user_tmp" \
        --rawfile a "$assistant_tmp" \
        --argjson max "$MAX_HISTORY_PAIRS" '
            (. + [{role: "user", content: $u}, {role: "assistant", content: $a}]) as $all
            | $all[([0, ($all | length) - (2 * $max)] | max):]
        ' > "$tmp" 2> "$err_tmp"; then
        if mv -f "$tmp" "$HISTORY_FILE"; then
            return 0
        fi
        echo "Предупреждение: не удалось обновить файл истории." >&2
        return 1
    fi

    echo "Предупреждение: не удалось сохранить историю диалога." >&2
    if [ -s "$err_tmp" ]; then
        sed 's/^/  /' "$err_tmp" >&2
    fi
    return 1
}

get_access_token() {
    local now cached_token cached_exp
    now=$(date +%s)

    if [ -f "$TOKEN_CACHE" ]; then
        { IFS= read -r cached_token; IFS= read -r cached_exp; } < "$TOKEN_CACHE" 2>/dev/null

        # Второй строкой хранится срок действия в секундах Unix-эпохи.
        if [ -n "$cached_token" ] && [ -n "$cached_exp" ] &&
            [ "$cached_exp" -gt "$now" ] 2>/dev/null; then
            printf '%s\n' "$cached_token"
            return 0
        fi
    fi

    local rquid
    rquid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)
    if [ -z "$rquid" ]; then
        echo "Ошибка: не удалось сгенерировать RqUID." >&2
        return 1
    fi

    local resp cfg http
    resp=$(make_tmp) || { echo "Ошибка: нет доступного временного файла." >&2; return 1; }
    cfg=$(make_tmp) || { echo "Ошибка: нет доступного временного файла." >&2; return 1; }

    # Заголовки передаются через конфиг curl, чтобы ключ не был виден в ps.
    {
        printf 'url = "%s"\n' "$(curl_escape "$OAUTH_URL")"
        printf 'header = "Accept: application/json"\n'
        printf 'header = "RqUID: %s"\n' "$(curl_escape "$rquid")"
        printf 'header = "Authorization: Basic %s"\n' "$(curl_escape "$GIGACHAT_CREDENTIALS")"
        printf 'header = "Content-Type: application/x-www-form-urlencoded"\n'
        printf 'data = "scope=GIGACHAT_API_PERS"\n'
    } > "$cfg"

    if ! http=$(curl -sS --connect-timeout 10 --max-time "$HTTP_TIMEOUT" \
        -K "$cfg" -o "$resp" -w '%{http_code}'); then
        echo "Ошибка: не удалось выполнить запрос токена." >&2
        return 1
    fi

    local token_response new_token exp_ms exp
    token_response=$(cat "$resp")
    new_token=$(printf '%s' "$token_response" | jq -r '.access_token // empty' 2>/dev/null)

    if [ -z "$new_token" ]; then
        echo "Ошибка получения токена (HTTP ${http:-?}):" >&2
        printf '%s\n' "$token_response" >&2
        return 1
    fi

    exp_ms=$(printf '%s' "$token_response" | jq -r '.expires_at // empty' 2>/dev/null)
    case "$exp_ms" in
        '' | *[!0-9]*) exp=$((now + TOKEN_TTL)) ;;
        *) exp=$((exp_ms / 1000)) ;;
    esac

    local cache_tmp
    if cache_tmp=$(mktemp "$CACHE_DIR/.gigachat_token.XXXXXX" 2>/dev/null); then
        TMP_FILES+=("$cache_tmp")
        printf '%s\n%s\n' "$new_token" "$exp" > "$cache_tmp" && mv -f "$cache_tmp" "$TOKEN_CACHE"
    fi

    printf '%s\n' "$new_token"
}

# Потоковый запрос: текст печатается по мере генерации, полный ответ
# сохраняется в $OUT_FILE (для истории), сырой поток — в $RAW_FILE.
stream_chat() {
    local token=$1 cfg curl_rc

    cfg=$(make_tmp) || return 1

    {
        printf 'url = "%s/v1/chat/completions"\n' "$(curl_escape "$BASE_URL")"
        printf 'header = "Accept: application/json"\n'
        printf 'header = "Authorization: Bearer %s"\n' "$(curl_escape "$token")"
    } > "$cfg"

    : > "$OUT_FILE"
    : > "$RAW_FILE"

    curl -sS -N --connect-timeout 10 --max-time "$HTTP_TIMEOUT" -X POST \
        -K "$cfg" \
        -H 'Content-Type: application/json; charset=utf-8' \
        -D "$HDR_FILE" \
        --data-binary "@$PAYLOAD_FILE" |
        tee "$RAW_FILE" |
        jq --unbuffered -Rj "$SSE_FILTER" |
        tee "$OUT_FILE"

    curl_rc=${PIPESTATUS[0]}
    return "$curl_rc"
}

# Код последнего HTTP-ответа из дампа заголовков: при HTTPS CONNECT
# и промежуточных 1xx в файле может быть несколько блоков.
response_code() {
    awk '/^HTTP\// { code=$2 } END { if (code != "") print code }' "$HDR_FILE" 2>/dev/null
}

prune_history

# ==============================================================
# Разбор аргументов
# ==============================================================
CUSTOM_SYSTEM_PROMPT=""
USE_HISTORY=0

while getopts ":s:mh" opt; do
    case $opt in
        s) CUSTOM_SYSTEM_PROMPT="$OPTARG" ;;
        m) USE_HISTORY=1 ;;
        h) print_usage 0 ;;
        :)
            echo "Ошибка: параметр -$OPTARG требует значения." >&2
            print_usage 2
            ;;
        \?)
            echo "Ошибка: неверный параметр -$OPTARG." >&2
            print_usage 2
            ;;
    esac
done

# Всё после флагов (в том числе после --) — текст запроса.
shift $((OPTIND - 1))

if [ $# -gt 0 ]; then
    USER_PROMPT="$*"

    # stdin используется как дополнение к аргументам, а не отбрасывается.
    if [ ! -t 0 ]; then
        STDIN_DATA=$(cat)
        if [ -n "$STDIN_DATA" ]; then
            USER_PROMPT+=$'\n\n'"$STDIN_DATA"
        fi
    fi
else
    if [ -t 0 ]; then
        echo "Введите запрос (завершите ввод нажатием Ctrl+D для отправки):" >&2
    fi
    USER_PROMPT=$(cat)
fi

if [ -z "$USER_PROMPT" ]; then
    echo "Ошибка: пустой запрос." >&2
    exit 2
fi

if [ -z "$GIGACHAT_CREDENTIALS" ]; then
    echo "Ошибка: переменная окружения GIGACHAT_CREDENTIALS не задана." >&2
    echo "Экспортируйте её: export GIGACHAT_CREDENTIALS='sb.0....ваш_ключ'" >&2
    exit 1
fi

if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    echo "Ошибка: не удалось создать каталог $CACHE_DIR." >&2
    exit 1
fi

prune_history

# Отдельный каталог запуска: конфиги curl с Authorization, тело запроса,
# ответ и заголовки удаляются на EXIT (включая ошибки и Ctrl+C).
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gigachat.XXXXXX") || {
    echo "Ошибка: не удалось создать временный каталог." >&2
    exit 1
}

# ==============================================================
# Запрос
# ==============================================================
if [ -n "$CUSTOM_SYSTEM_PROMPT" ]; then
    SYSTEM_CONTEXT="$CUSTOM_SYSTEM_PROMPT"
else
    SYSTEM_CONTEXT="Ты — полезный ИИ-ассистент, встроенный в терминал. Отвечай кратко."
fi

if [ "$USE_HISTORY" -eq 1 ]; then
    HISTORY_JSON=$(load_history)
else
    HISTORY_JSON='[]'
fi

# Большие данные передаём в jq через файлы: аргументы командной строки
# ограничены ARG_MAX (в Linux — около 128 КиБ на аргумент).
SYSTEM_FILE=$(make_tmp) || { echo "Ошибка: нет доступного временного файла." >&2; exit 1; }
PROMPT_FILE=$(make_tmp) || { echo "Ошибка: нет доступного временного файла." >&2; exit 1; }
HISTORY_TMP=$(make_tmp) || { echo "Ошибка: нет доступного временного файла." >&2; exit 1; }

printf '%s' "$SYSTEM_CONTEXT" > "$SYSTEM_FILE"
printf '%s' "$USER_PROMPT" > "$PROMPT_FILE"
printf '%s' "$HISTORY_JSON" > "$HISTORY_TMP"

PAYLOAD_FILE=$(make_tmp) || { echo "Ошибка: нет доступного временного файла." >&2; exit 1; }

if ! jq -n \
    --arg model "$MODEL" \
    --rawfile sys_content "$SYSTEM_FILE" \
    --rawfile user_content "$PROMPT_FILE" \
    --slurpfile history "$HISTORY_TMP" \
    '{
        model: $model,
        messages: ([{role: "system", content: $sys_content}] + $history[0] +
                   [{role: "user", content: $user_content}]),
        stream: true
    }' > "$PAYLOAD_FILE"; then
    echo "Ошибка: не удалось сформировать JSON-запрос (jq)." >&2
    exit 1
fi

OUT_FILE=$(make_tmp) || { echo "Ошибка: нет доступного временного файла." >&2; exit 1; }
RAW_FILE=$(make_tmp) || { echo "Ошибка: нет доступного временного файла." >&2; exit 1; }
HDR_FILE=$(make_tmp) || { echo "Ошибка: нет доступного временного файла." >&2; exit 1; }

ACCESS_TOKEN=$(get_access_token) || exit 1
if [ -z "$ACCESS_TOKEN" ]; then
    exit 1
fi

if ! stream_chat "$ACCESS_TOKEN"; then
    echo "Ошибка: не удалось подключиться к API GigaChat." >&2
    exit 1
fi

HTTP_CODE=$(response_code)

# Токен мог быть отозван или протухнуть раньше срока — обновляем и повторяем один раз.
if [ "$HTTP_CODE" = "401" ]; then
    echo "Токен отклонён сервером, получаю новый." >&2
    rm -f "$TOKEN_CACHE"
    ACCESS_TOKEN=$(get_access_token) || exit 1
    if [ -z "$ACCESS_TOKEN" ]; then
        exit 1
    fi
    if ! stream_chat "$ACCESS_TOKEN"; then
        echo "Ошибка: не удалось подключиться к API GigaChat." >&2
        exit 1
    fi
    HTTP_CODE=$(response_code)
fi

AI_TEXT=""

if [ -s "$OUT_FILE" ]; then
    AI_TEXT=$(cat "$OUT_FILE")
    # Стриминг печатает без завершающего перевода строки.
    printf '\n'
elif [ "$HTTP_CODE" = "200" ]; then
    # Поток не распознан (прокси мог отключить SSE) — пробуем цельный JSON-ответ.
    AI_TEXT=$(jq -r '.choices[0].message.content // empty' "$RAW_FILE" 2>/dev/null)
    if [ -n "$AI_TEXT" ]; then
        printf '%s\n' "$AI_TEXT"
    fi
fi

if [ -z "$AI_TEXT" ]; then
    API_ERROR=$(jq -r '.error.message // .message // empty' "$RAW_FILE" 2>/dev/null)

    if [ -n "$API_ERROR" ]; then
        echo "Ошибка API GigaChat: $API_ERROR" >&2
    else
        echo "Ошибка API GigaChat: пустой ответ (HTTP ${HTTP_CODE:-?})." >&2
        head -c 500 "$RAW_FILE" >&2 2>/dev/null
        echo >&2
    fi
    exit 1
fi

# История — часть результата: при ошибке save_history выводит предупреждение,
# а ненулевой код возврата сигнализирует, что следующий -m не увидит этот обмен.
save_history "$HISTORY_JSON" "$USER_PROMPT" "$AI_TEXT"
