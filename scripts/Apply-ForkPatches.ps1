$ErrorActionPreference = 'Stop'

$sourcePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\RetainerTaskExecutor.cs'
$content = Get-Content -LiteralPath $sourcePath -Raw

# If upstream eventually handles the greeting itself, do not inject a duplicate handler.
$methodPattern = '(?s)private\s+CraftingTasks\.TaskResult\s+TickWaitRetainerMenu\(\)\s*\{(?<body>.*?)(?=\n\s*private\s+CraftingTasks\.TaskResult\s+TickSelectEntrustWithdraw\(\))'
$methodMatch = [regex]::Match($content, $methodPattern)
if (-not $methodMatch.Success) {
    throw 'Could not locate TickWaitRetainerMenu(). Upstream likely changed; review the fork patch.'
}

if ($methodMatch.Groups['body'].Value -match 'TryGetAddonByName<AddonTalk>\("Talk"') {
    Write-Host 'TickWaitRetainerMenu already handles Talk; no fork patch needed.'
    exit 0
}

$methodStartPattern = '(?ms)(private\s+CraftingTasks\.TaskResult\s+TickWaitRetainerMenu\(\)\s*\{\s*)'
$handler = @'
        if (GenericHelpers.TryGetAddonByName<AddonTalk>("Talk", out var talk) && talk->AtkUnitBase.IsVisible)
        {
            GatherBuddy.Log.Debug("[RetainerTaskExecutor] Retainer greeting visible, dismissing");
            new AddonMaster.Talk((nint)talk).Click();
            Delay(300);
            return CraftingTasks.TaskResult.Retry;
        }

'@

$patched = [regex]::Replace(
    $content,
    $methodStartPattern,
    { param($m) $m.Groups[1].Value + $handler },
    1
)

if ($patched -eq $content) {
    throw 'Retainer greeting patch was not applied.'
}

Set-Content -LiteralPath $sourcePath -Value $patched -Encoding utf8 -NoNewline
Write-Host 'Applied fork patch: auto-dismiss retainer greeting while waiting for retainer menu.'
