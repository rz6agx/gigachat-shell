@{
    RootModule        = 'GigaChat.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '7c4a8f21-6d93-4b52-ae17-83f09c2d614b'
    Author            = 'rz6agx'
    Description       = 'Консольный помощник на базе API GigaChat'
    PowerShellVersion = '7.0'

    FunctionsToExport = @('gpt')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData = @{
        PSData = @{
            Tags = @('GigaChat', 'AI', 'CLI')
        }
    }
}
