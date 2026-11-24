@{
    RootModule           = 'GigaChat.psm1'
    ModuleVersion        = '1.2.0'
    GUID                 = '7c4a8f21-6d93-4b52-ae17-83f09c2d614b'
    Author               = 'rz6agx'
    Copyright            = '(c) 2026 Vlad Kostenko. MIT License.'
    Description          = 'Консольный помощник на базе API GigaChat'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @('gpt')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData = @{
        PSData = @{
            Tags         = @('GigaChat', 'AI', 'CLI', 'ChatGPT', 'LLM')
            LicenseUri   = 'https://github.com/rz6agx/gigachat-shell/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/rz6agx/gigachat-shell'
            ReleaseNotes = @'
1.2.0 — метаданные модуля: ProjectUri, LicenseUri, Copyright, CompatiblePSEditions.
Код модуля не менялся.
'@
        }
    }
}
