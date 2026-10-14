#!/bin/bash

# Перехватываем Ctrl+C (сигнал SIGINT) для красивого выхода при вводе текста
trap 'echo -e "\nВвод прерван."; exit 130' INT

# ==============================================================
# USAGE:
# gpt [-s "Системный промпт"] "ваш запрос"
#   -s  Использовать кастомный системный промпт вместо стандартного.
#       Пример: gpt -s "Ты — Senior Python Developer" "Напиши код"
# ==============================================================
# INSTALL:
# cp gpt.sh /usr/local/bin/gpt
# chmod +x /usr/local/bin/gpt
# ==============================================================

# Функция вывода справки
print_usage() {
    echo "Использование: $0 [-s \"Системный промпт\"] \"ваш запрос\""
    echo "  -s  Кастомный системный промпт."
    exit 0
}

# Проверяем наличие авторизационных данных
if [ -z "$GIGACHAT_CREDENTIALS" ]; then
    echo "Ошибка: Переменная окружения GIGACHAT_CREDENTIALS не задана." >&2
    echo "Экспортируйте её: export GIGACHAT_CREDENTIALS='sb.0....ваш_ключ'" >&2
    exit 1
fi

BASE_URL="https://api.giga.chat"
TOKEN_CACHE="/tmp/.gigachat_token"
TOKEN_TTL=1500

# Функция получения и кэширования токена
get_access_token() {
    if [ -f "$TOKEN_CACHE" ]; then
        local cached_token
        local token_time
        cached_token=$(head -n1 "$TOKEN_CACHE")
        token_time=$(stat -c %Y "$TOKEN_CACHE" 2>/dev/null || stat -f %m "$TOKEN_CACHE" 2>/dev/null)
        local current_time
        current_time=$(date +%s)

        if [ "$current_time" -lt $((token_time + TOKEN_TTL)) ] && [ -n "$cached_token" ]; then
            printf '%s\n' "$cached_token"
            return 0
        fi
    fi

    local rquid
    rquid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null) || {
        echo "Ошибка: не удалось сгенерировать RqUID." >&2
        return 1
    }

    local response_file="/tmp/gigachat_oauth_resp.json"

    if ! curl -sS -X POST 'https://ngw.devices.sberbank.ru:9443/api/v2/oauth' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H 'Accept: application/json' \
        -H "RqUID: $rquid" \
        -H "Authorization: Basic $GIGACHAT_CREDENTIALS" \
        --data-urlencode 'scope=GIGACHAT_API_PERS' \
        -o "$response_file"; then
        echo "Ошибка: не удалось выполнить запрос токена." >&2
        return 1
    fi

    local token_response
    token_response=$(cat "$response_file")

    local new_token
    new_token=$(printf '%s' "$token_response" | jq -r '.access_token // empty')

    if [ -n "$new_token" ]; then
        printf '%s\n' "$new_token" > "$TOKEN_CACHE"
        printf '%s\n' "$new_token"
    else
        echo "Ошибка получения токена:" >&2
        printf '%s\n' "$token_response" >&2
        return 1
    fi
}

# Обработка флагов (ВАЖНО: должны передаваться до основного текста запроса)
CUSTOM_SYSTEM_PROMPT=""
while getopts ":s:h" opt; do
  case $opt in
    s)
      CUSTOM_SYSTEM_PROMPT="$OPTARG"
      ;;
    h)
      print_usage
      ;;
    \?)
      echo "Неверный параметр: -$OPTARG" >&2
      print_usage
      ;;
  esac
done

# Сдвигаем указатель аргументов, чтобы $@ содержал только текст запроса
shift $((OPTIND -1))

# Режим чтения из stdin, если нет аргументов
if [ $# -eq 0 ]; then
    if [ -t 0 ]; then
        echo "Введите запрос (Завершите ввод нажатием Ctrl+D для отправки):"
    fi
    USER_PROMPT=$(cat)
else
    USER_PROMPT="$*"
fi

if [ -z "$USER_PROMPT" ]; then
    echo "Ошибка: Пустой запрос." >&2
    exit 1
fi

# Формирование системного контекста (с учетом флага -s)
if [ -n "$CUSTOM_SYSTEM_PROMPT" ]; then
    SYSTEM_CONTEXT="$CUSTOM_SYSTEM_PROMPT"
else
    SYSTEM_CONTEXT="Ты — полезный ИИ-ассистент, встроенный в Терминал MacOS. Отвечай кратко."
fi

ACCESS_TOKEN=$(get_access_token)
if [ -z "$ACCESS_TOKEN" ]; then
    exit 1
fi

JSON_PAYLOAD=$(jq -n \
    --arg sys_content "$SYSTEM_CONTEXT" \
    --arg user_content "$USER_PROMPT" \
    '{
        model: "GigaChat-2-Pro",
        messages: [
            {role: "system", content: $sys_content},
            {role: "user", content: $user_content}
        ],
        stream: false
    }')

RESPONSE=$(curl -sS -X POST "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "$JSON_PAYLOAD") || {
        echo "Ошибка: не удалось подключиться к API GigaChat." >&2
        exit 1
    }

# Проверяем, что ответ является корректным JSON
if ! printf '%s' "$RESPONSE" | jq -e . >/dev/null 2>&1; then
    echo "Ошибка: сервер вернул некорректный JSON." >&2
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

printf '%s\n' "$AI_TEXT"
