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
#   -m  Продолжить предыдущий диалог (до 10 пар вопрос-ответ).
#       Без -m история диалога очищается.
#   -h  Показать справку.
#
# Запрос можно передать через stdin:
#   journalctl -p err -n 50 | gpt "Проанализируй ошибки"
# Если запрос передан и аргументом, и через stdin, содержимое stdin
# добавляется к запросу отдельным блоком.
#
# Настройки через переменные окружения:
#   GIGACHAT_CREDENTIALS  ключ авторизации (обязательно)
#   GIGACHAT_MODEL        модель (по умолчанию GigaChat-2-Max)
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
MODEL="${GIGACHAT_MODEL:-GigaChat-2-Max}"
HTTP_TIMEOUT="${GIGACHAT_TIMEOUT:-120}"

TOKEN_TTL=1500
MAX_HISTORY_PAIRS=10

CACHE_DIR="$HOME/.local"
TOKEN_CACHE="$CACHE_DIR/gigachat_token"
HISTORY_FILE="$CACHE_DIR/gigachat_history.json"

# Временные файлы (в них лежат токен и тело запроса) удаляются при выходе.
TMP_FILES=()

cleanup() {
    [ ${#TMP_FILES[@]} -eq 0 ] || rm -f "${TMP_FILES[@]}"
    return 0
}
trap cleanup EXIT

make_tmp() {
    local file
    file=$(mktemp) || return 1
    TMP_FILES+=("$file")
    printf '%s\n' "$file"
}

# Экранирование значения для конфигурационного файла curl.
curl_escape() {
    printf '%s' "$1" | sed 's/[\\"]/\\&/g'
}

print_usage() {
    echo "Использование: $0 [-s \"Системный промпт\"] [-m] \"ваш запрос\""
    echo "  -s  Кастомный системный промпт."
    echo "  -m  Продолжить предыдущий диалог."
    echo "  -h  Показать справку."
    exit "$1"
}

# Печатает историю диалога как JSON-массив сообщений.
load_history() {
    if [ -f "$HISTORY_FILE" ]; then
        jq -c 'if type == "array" then . else [] end' "$HISTORY_FILE" 2>/dev/null && return 0
    fi
    printf '[]\n'
}

# История перезаписывается целиком: контекст отправленного запроса + новый обмен.
save_history() {
    local history=$1 user=$2 assistant=$3 tmp out

    tmp=$(mktemp "$CACHE_DIR/.gigachat_history.XXXXXX" 2>/dev/null) || return 0
    TMP_FILES+=("$tmp")

    if out=$(printf '%s' "$history" | jq -c \
        --arg u "$user" \
        --arg a "$assistant" \
        --argjson max "$MAX_HISTORY_PAIRS" '
            (. + [{role: "user", content: $u}, {role: "assistant", content: $a}]) as $all
            | $all[([0, ($all | length) - (2 * $max)] | max):]
        ' 2>/dev/null); then
        printf '%s\n' "$out" > "$tmp" && mv -f "$tmp" "$HISTORY_FILE"
    fi
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

# Возвращает HTTP-код ответа, тело пишет в третий аргумент.
chat_request() {
    local token=$1 payload_file=$2 out_file=$3 cfg http

    cfg=$(make_tmp) || return 1

    {
        printf 'url = "%s/v1/chat/completions"\n' "$(curl_escape "$BASE_URL")"
        printf 'header = "Accept: application/json"\n'
        printf 'header = "Authorization: Bearer %s"\n' "$(curl_escape "$token")"
    } > "$cfg"

    http=$(curl -sS --connect-timeout 10 --max-time "$HTTP_TIMEOUT" -X POST \
        -K "$cfg" \
        -H 'Content-Type: application/json; charset=utf-8' \
        --data-binary "@$payload_file" \
        -o "$out_file" -w '%{http_code}') || return 1

    printf '%s\n' "$http"
}

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

JSON_PAYLOAD=$(jq -n \
    --arg model "$MODEL" \
    --arg sys_content "$SYSTEM_CONTEXT" \
    --arg user_content "$USER_PROMPT" \
    --argjson history "$HISTORY_JSON" \
    '{
        model: $model,
        messages: ([{role: "system", content: $sys_content}] + $history +
                   [{role: "user", content: $user_content}]),
        stream: false
    }')

ACCESS_TOKEN=$(get_access_token) || exit 1
if [ -z "$ACCESS_TOKEN" ]; then
    exit 1
fi

PAYLOAD_FILE=$(make_tmp) || { echo "Ошибка: нет доступного временного файла." >&2; exit 1; }
printf '%s' "$JSON_PAYLOAD" > "$PAYLOAD_FILE"

RESPONSE_FILE=$(make_tmp) || { echo "Ошибка: нет доступного временного файла." >&2; exit 1; }

if ! HTTP_CODE=$(chat_request "$ACCESS_TOKEN" "$PAYLOAD_FILE" "$RESPONSE_FILE"); then
    echo "Ошибка: не удалось подключиться к API GigaChat." >&2
    exit 1
fi

# Токен мог быть отозван или протухнуть раньше срока — обновляем и повторяем один раз.
if [ "$HTTP_CODE" = "401" ]; then
    echo "Токен отклонён сервером, получаю новый." >&2
    rm -f "$TOKEN_CACHE"
    ACCESS_TOKEN=$(get_access_token) || exit 1
    if [ -z "$ACCESS_TOKEN" ]; then
        exit 1
    fi
    if ! HTTP_CODE=$(chat_request "$ACCESS_TOKEN" "$PAYLOAD_FILE" "$RESPONSE_FILE"); then
        echo "Ошибка: не удалось подключиться к API GigaChat." >&2
        exit 1
    fi
fi

RESPONSE=$(cat "$RESPONSE_FILE")

# Проверяем, что ответ является корректным JSON
if ! printf '%s' "$RESPONSE" | jq -e . >/dev/null 2>&1; then
    echo "Ошибка: сервер вернул некорректный JSON (HTTP ${HTTP_CODE:-?})." >&2
    printf '%s\n' "$RESPONSE" >&2
    exit 1
fi

# Проверяем ошибки API
if ! AI_TEXT=$(printf '%s' "$RESPONSE" | jq -er '
    if .choices[0].message.content? then
        .choices[0].message.content
    elif .error then
        error(.error.message // (.error | tostring))
    elif .message then
        error(.message)
    else
        error("Неизвестный формат ответа API")
    end
'); then
    echo "Ошибка API GigaChat." >&2
    exit 1
fi

if [ -z "$AI_TEXT" ]; then
    echo "Ошибка API GigaChat: модель вернула пустой ответ." >&2
    exit 1
fi

printf '%s\n' "$AI_TEXT"

save_history "$HISTORY_JSON" "$USER_PROMPT" "$AI_TEXT"
