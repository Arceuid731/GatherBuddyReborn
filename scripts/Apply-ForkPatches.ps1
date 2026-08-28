$ErrorActionPreference = 'Stop'

# --- Vulcan retainer greeting fix -------------------------------------------------
$retainerPath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\RetainerTaskExecutor.cs'
$retainerContent = Get-Content -LiteralPath $retainerPath -Raw

# If upstream eventually handles the greeting itself, do not inject a duplicate handler.
$methodPattern = '(?s)private\s+CraftingTasks\.TaskResult\s+TickWaitRetainerMenu\(\)\s*\{(?<body>.*?)(?=\r?\n\s*private\s+CraftingTasks\.TaskResult\s+TickSelectEntrustWithdraw\(\))'
$methodMatch = [regex]::Match($retainerContent, $methodPattern)
if (-not $methodMatch.Success) {
    throw 'Could not locate TickWaitRetainerMenu(). Upstream likely changed; review the fork patch.'
}

if ($methodMatch.Groups['body'].Value -match 'TryGetAddonByName<AddonTalk>\("Talk"') {
    Write-Host 'TickWaitRetainerMenu already handles Talk; retainer greeting patch is no longer needed.'
}
else {
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

    $patchedRetainer = [regex]::Replace(
        $retainerContent,
        $methodStartPattern,
        { param($m) $m.Groups[1].Value + $handler },
        1
    )

    if ($patchedRetainer -eq $retainerContent) {
        throw 'Retainer greeting patch was not applied.'
    }

    Set-Content -LiteralPath $retainerPath -Value $patchedRetainer -Encoding utf8 -NoNewline
    Write-Host 'Applied fork patch: auto-dismiss retainer greeting while waiting for retainer menu.'
}

# --- Current upstream build compatibility ----------------------------------------
# With the current Dalamud/.NET toolchain, GetAddonByName returns a pointer-backed
# type whose implicit conversion now requires an unsafe context. Upstream main has
# two affected helpers. Keep these build-only compatibility edits conditional so
# they disappear automatically once upstream marks the methods unsafe itself.
$interopPath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingGameInterop.cs'
$interopContent = Get-Content -LiteralPath $interopPath -Raw
$interopPatched = $interopContent

$compatibilityMethods = @(
    'TransitionFromWaitFinish',
    'GetRecipeIdFromUI'
)

foreach ($methodName in $compatibilityMethods) {
    $unsafePattern = "private\s+static\s+unsafe\s+[^\r\n]+\s+$methodName\("
    if ($interopPatched -match $unsafePattern) {
        Write-Host "$methodName is already unsafe; compatibility patch not needed."
        continue
    }

    $declarationPattern = "private\s+static\s+(?<returnType>[^\r\n]+?)\s+$methodName\("
    $match = [regex]::Match($interopPatched, $declarationPattern)
    if (-not $match.Success) {
        throw "Could not locate $methodName(). Upstream likely changed; review the compatibility patch."
    }

    $oldDeclaration = $match.Value
    $newDeclaration = $oldDeclaration -replace '^private\s+static\s+', 'private static unsafe '
    $interopPatched = $interopPatched.Replace($oldDeclaration, $newDeclaration)
    Write-Host "Applied build compatibility patch: marked $methodName unsafe."
}

if ($interopPatched -ne $interopContent) {
    Set-Content -LiteralPath $interopPath -Value $interopPatched -Encoding utf8 -NoNewline
}
