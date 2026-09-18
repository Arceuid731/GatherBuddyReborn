$ErrorActionPreference = 'Stop'
$bridgePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingGatherBridge.cs'
$bridge = Get-Content -LiteralPath $bridgePath -Raw
$old = 'All required materials are in the inventory and the current area is safe; continuing to crafting.'
$new = 'Gathering complete; checking the remaining crafting steps.'
if ($bridge.Contains($old)) {
    $bridge = $bridge.Replace($old, $new)
    Set-Content -LiteralPath $bridgePath -Value $bridge -Encoding utf8 -NoNewline
} elseif (-not $bridge.Contains($new)) {
    throw 'Could not update the acquisition completion message.'
}
