#requires -Version 7.0

# ==============================================================
# USAGE:
# gpt [-s "Системный промпт"] "ваш запрос"
# gpt -h
#
# Если аргументов нет, запрос читается из stdin.
# ==============================================================

function gpt {

$ErrorActionPreference = 'Stop'

$BaseUrl = 'https://api.giga.chat'
$OAuthUrl = 'https://ngw.devices.sberbank.ru:9443/api/v2/oauth'
$TokenTtl = 1500

$CacheDir = Join-Path $env:LOCALAPPDATA 'gpt'
$TokenCache = Join-Path $CacheDir 'gigachat_token'

$DefaultSystemPrompt = 'Ты — полезный ИИ-ассистент, встроенный в Терминал Windows. Отвечай кратко.'

function Write-ErrorMessage {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    Write-Output 'Использование: gpt [-s "Системный промпт"] "ваш запрос"'
    Write-Output '  -s  Кастомный системный промпт.'
    Write-Output '  -h  Показать справку.'
}

function Get-AccessToken {
    # Используем кэш, пока токен не старше TTL.
    if (Test-Path -LiteralPath $TokenCache -PathType Leaf) {
        try {
            $CachedToken = (Get-Content -LiteralPath $TokenCache -Raw).Trim()
            $TokenTime = (Get-Item -LiteralPath $TokenCache).LastWriteTimeUtc
            $Age = ([DateTime]::UtcNow - $TokenTime).TotalSeconds

            if ($CachedToken -and $Age -ge 0 -and $Age -lt $TokenTtl) {
                return $CachedToken
            }
        }
        catch {
            # Повреждённый кэш: получаем новый токен.
        }
    }

    if (-not $env:GIGACHAT_CREDENTIALS) {
        throw 'Переменная окружения GIGACHAT_CREDENTIALS не задана.'
    }

    $RqUID = [Guid]::NewGuid().ToString()

    $Headers = @{
        'Accept'        = 'application/json'
        'RqUID'         = $RqUID
        'Authorization' = "Basic $env:GIGACHAT_CREDENTIALS"
    }

    try {
        $TokenResponse = Invoke-RestMethod `
            -Uri $OAuthUrl `
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
        New-Item -ItemType Directory -Path $CacheDir -Force |
            Out-Null

        Set-Content -LiteralPath $TokenCache `
            -Value $NewToken `
            -NoNewline `
            -Encoding utf8
    }
    catch {
        # Работаем и без кэша, если запись недоступна.
    }

    return $NewToken
}

# Разбираем аргументы командной строки.
$ScriptArgs = @($args)
$CustomSystemPrompt = $null
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

# Получаем запрос из аргументов или стандартного ввода.
if ($PromptParts.Count -gt 0) {
    $UserPrompt = $PromptParts -join ' '
}
else {
    if ([Console]::IsInputRedirected) {
        $UserPrompt = [Console]::In.ReadToEnd()
    }
    else {
        Write-Output 'Введите запрос (Ctrl+Z, затем Enter для отправки):'
        $UserPrompt = [Console]::In.ReadToEnd()
    }
}

if ([string]::IsNullOrWhiteSpace($UserPrompt)) {
    Write-ErrorMessage 'Ошибка: пустой запрос.'
    return
}

if ($CustomSystemPrompt) {
    $SystemContext = $CustomSystemPrompt
}
else {
    $SystemContext = $DefaultSystemPrompt
}

try {
    $AccessToken = Get-AccessToken
}
catch {
    Write-ErrorMessage "Ошибка: $($_.Exception.Message)"
    return
}

$Payload = @{
    model = 'GigaChat-2-Pro'
    messages = @(
        @{
            role    = 'system'
            content = $SystemContext
        }
        @{
            role    = 'user'
            content = $UserPrompt
        }
    )
    stream = $false
}

$JsonPayload = $Payload | ConvertTo-Json -Depth 10 -Compress

try {
    $Response = Invoke-RestMethod `
        -Uri "$BaseUrl/v1/chat/completions" `
        -Method Post `
        -Headers @{
            'Accept'        = 'application/json'
            'Authorization' = "Bearer $AccessToken"
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

[Console]::Out.WriteLine([string]$AIText)

}

Export-ModuleMember -Function gpt
