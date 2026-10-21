#requires -Version 7.0

# ==============================================================
# USAGE:
# gpt [-s "Кастомный промпт"] [-m] "ваш запрос"
# gpt -h
#
# -s  Кастомный системный промпт.
# -m  Продолжить предыдущий диалог.
# -h  Показать справку.
#
# Без -m история диалога очищается.
# ==============================================================

# Настройки модуля
$script:BaseUrl = 'https://api.giga.chat'
$script:OAuthUrl = 'https://ngw.devices.sberbank.ru:9443/api/v2/oauth'
$script:TokenTtl = 1500

$script:CacheDir = Join-Path $env:LOCALAPPDATA 'gpt'
$script:TokenCache = Join-Path $script:CacheDir 'gigachat_token'

$script:DefaultSystemPrompt = 'Ты — полезный ИИ-ассистент, встроенный в Терминал Windows. Отвечай кратко.'

# Память диалога
$script:MaxHistoryPairs = 10
$script:GigaChatHistory = [System.Collections.Generic.List[hashtable]]::new()

function Write-ErrorMessage {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    Write-Output 'Использование: gpt [-s "Кастомный промпт"] [-m] "ваш запрос"'
    Write-Output '  -s  Кастомный системный промпт.'
    Write-Output '  -m  Продолжить предыдущий диалог.'
    Write-Output '  -h  Показать справку.'
}

function Get-AccessToken {
    if (Test-Path -LiteralPath $script:TokenCache -PathType Leaf) {
        try {
            $CachedToken = (Get-Content -LiteralPath $script:TokenCache -Raw).Trim()
            $TokenTime = (Get-Item -LiteralPath $script:TokenCache).LastWriteTimeUtc
            $Age = ([DateTime]::UtcNow - $TokenTime).TotalSeconds

            if ($CachedToken -and $Age -ge 0 -and $Age -lt $script:TokenTtl) {
                return $CachedToken
            }
        }
        catch {
            # При ошибке чтения кеша получаем новый токен.
        }
    }

    if (-not $env:GIGACHAT_CREDENTIALS) {
        throw 'Переменная окружения GIGACHAT_CREDENTIALS не задана.'
    }

    $Headers = @{
        Accept        = 'application/json'
        RqUID         = [Guid]::NewGuid().ToString()
        Authorization = "Basic $env:GIGACHAT_CREDENTIALS"
    }

    try {
        $TokenResponse = Invoke-RestMethod `
            -Uri $script:OAuthUrl `
            -Method Post `
            -Headers $Headers `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body 'scope=GIGACHAT_API_PERS'
    }
    catch {
        $Details = $_.ErrorDetails.Message
        if (-not $Details) {
            $Details = $_.Exception.Message
        }

        throw "Не удалось получить OAuth-токен: $Details"
    }

    $NewToken = $TokenResponse.access_token

    if (-not $NewToken) {
        $Details = $TokenResponse | ConvertTo-Json -Depth 10 -Compress
        throw "В ответе OAuth отсутствует access_token: $Details"
    }

    try {
        New-Item -ItemType Directory -Path $script:CacheDir -Force |
            Out-Null

        Set-Content -LiteralPath $script:TokenCache `
            -Value $NewToken `
            -NoNewline `
            -Encoding utf8
    }
    catch {
        # Работаем и без кеширования токена.
    }

    return $NewToken
}

function Trim-GigaChatHistory {
    $MaxMessages = $script:MaxHistoryPairs * 2

    if ($script:GigaChatHistory.Count -gt $MaxMessages) {
        $Excess = $script:GigaChatHistory.Count - $MaxMessages
        $script:GigaChatHistory.RemoveRange(0, $Excess)
    }
}

function gpt {
    $ErrorActionPreference = 'Stop'

    # Разбор аргументов
    $ScriptArgs = @($args)
    $CustomSystemPrompt = $null
    $UseMemory = $false
    $PromptParts = [System.Collections.Generic.List[string]]::new()

    for ($i = 0; $i -lt $ScriptArgs.Count; $i++) {
        $Arg = [string]$ScriptArgs[$i]

        switch ($Arg) {
            '-h' {
                Show-Usage
                return
            }

            '-s' {
                if ($i + 1 -ge $ScriptArgs.Count) {
                    Write-ErrorMessage 'Ошибка: после -s требуется системный промпт.'
                    return
                }

                $i++
                $CustomSystemPrompt = [string]$ScriptArgs[$i]
            }

            '-m' {
                $UseMemory = $true
            }

            default {
                if ($Arg.StartsWith('-')) {
                    Write-ErrorMessage "Неверный параметр: $Arg"
                    Show-Usage
                    return
                }

                $PromptParts.Add($Arg)
            }
        }
    }

    # Получение запроса из аргументов или stdin
    if ($PromptParts.Count -gt 0) {
        $UserPrompt = $PromptParts -join ' '
    }
    else {
        if (-not [Console]::IsInputRedirected) {
            Write-Output 'Введите запрос (Ctrl+Z, затем Enter для отправки):'
        }

        $UserPrompt = [Console]::In.ReadToEnd()
    }

    if ([string]::IsNullOrWhiteSpace($UserPrompt)) {
        Write-ErrorMessage 'Ошибка: пустой запрос.'
        return
    }

    # Системный промпт текущего запроса
    if ($null -ne $CustomSystemPrompt) {
        $SystemContext = $CustomSystemPrompt
    }
    else {
        $SystemContext = $script:DefaultSystemPrompt
    }

    # Без -m начинаем новый диалог
    if (-not $UseMemory) {
        $script:GigaChatHistory.Clear()
    }

    # Получение токена
    try {
        $AccessToken = Get-AccessToken
    }
    catch {
        Write-ErrorMessage "Ошибка: $($_.Exception.Message)"
        return
    }

    # Сборка контекста
    $Messages = [System.Collections.Generic.List[hashtable]]::new()

    $Messages.Add(@{
        role    = 'system'
        content = $SystemContext
    })

    foreach ($Message in $script:GigaChatHistory) {
        $Messages.Add($Message)
    }

    $Messages.Add(@{
        role    = 'user'
        content = $UserPrompt
    })

    $Payload = @{
        model    = 'GigaChat-2-Pro'
        messages = $Messages
        stream   = $false
    }

    $JsonPayload = $Payload | ConvertTo-Json -Depth 10 -Compress

    # Запрос к API
    try {
        $Response = Invoke-RestMethod `
            -Uri "$script:BaseUrl/v1/chat/completions" `
            -Method Post `
            -Headers @{
                Accept        = 'application/json'
                Authorization = "Bearer $AccessToken"
            } `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($JsonPayload))
    }
    catch {
        $Details = $_.ErrorDetails.Message
        if (-not $Details) {
            $Details = $_.Exception.Message
        }

        Write-ErrorMessage "Ошибка: не удалось выполнить запрос к API GigaChat: $Details"
        return
    }

    # Проверка ответа
    $AIText = $Response.choices[0].message.content

    if ($null -eq $AIText) {
        if ($Response.error) {
            $ApiError = $Response.error.message

            if (-not $ApiError) {
                $ApiError = $Response.error | ConvertTo-Json -Compress -Depth 10
            }

            Write-ErrorMessage "Ошибка API GigaChat: $ApiError"
        }
        elseif ($Response.message) {
            Write-ErrorMessage "Ошибка API GigaChat: $($Response.message)"
        }
        else {
            $Details = $Response | ConvertTo-Json -Compress -Depth 10
            Write-ErrorMessage "Ошибка API GigaChat: неизвестный формат ответа. $Details"
        }

        return
    }

    # Вывод результата
    [Console]::Out.WriteLine([string]$AIText)

    # Сохранение только успешно завершённого обмена
    $script:GigaChatHistory.Add(@{
        role    = 'user'
        content = $UserPrompt
    })

    $script:GigaChatHistory.Add(@{
        role    = 'assistant'
        content = $AIText
    })

    # Сохраняем не более N полных пар вопрос-ответ
    Trim-GigaChatHistory
}

Export-ModuleMember -Function gpt
