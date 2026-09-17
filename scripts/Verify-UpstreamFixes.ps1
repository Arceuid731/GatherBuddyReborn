$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$retainer = Get-Content (Join-Path $root 'GatherBuddy/Crafting/RetainerTaskExecutor.cs') -Raw
$method = [regex]::Match($retainer, '(?s)private\s+CraftingTasks\.TaskResult\s+TickWaitRetainerMenu\(\)\s*\{(?<body>.*?)(?=\r?\n\s*private\s+CraftingTasks\.TaskResult\s+TickSelectEntrustWithdraw\()')
if (-not $method.Success) { throw 'Retainer greeting method changed; review the upstream fix.' }
$body = $method.Groups['body'].Value
if ([regex]::Matches($body, 'TryGetAddonByName<AddonTalk>\("Talk"').Count -ne 1 -or
    [regex]::Matches($body, 'new AddonMaster\.Talk\(\(nint\)talk\)\.Click\(\)').Count -ne 1) {
    throw 'Expected exactly one upstream retainer greeting handler and click.'
}
$interop = Get-Content (Join-Path $root 'GatherBuddy/Crafting/CraftingGameInterop.cs') -Raw
foreach ($methodName in @('TransitionFromWaitFinish', 'GetRecipeIdFromUI')) {
    if ([regex]::Matches($interop, "private\s+static\s+unsafe\s+[^\r\n]+\s+$methodName\(").Count -ne 1) {
        throw "Missing or duplicated upstream unsafe declaration: $methodName"
    }
}
$basePatch = Get-Content (Join-Path $PSScriptRoot 'Apply-ForkPatches.ps1') -Raw
if ($basePatch -match 'TickWaitRetainerMenu|compatibilityMethods|oldDeclaration|retainer greeting visible') {
    throw 'A retired upstream-equivalent patch was reintroduced.'
}
Write-Output 'PASS: one upstream greeting handler, two upstream unsafe declarations, no retired patch injection.'
