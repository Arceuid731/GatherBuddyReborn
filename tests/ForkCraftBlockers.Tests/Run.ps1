$ErrorActionPreference = 'Stop'
# Compile the real state-transition methods against a minimal game boundary.
# This exercises queue behavior without requiring a running Dalamud client.
function Get-Method([string]$source, [string]$signature) {
    $start = $source.IndexOf($signature)
    if ($start -lt 0) { throw "Missing method: $signature" }
    $open = $source.IndexOf('{', $start)
    $depth = 1
    $end = $open + 1
    while ($depth -gt 0 -and $end -lt $source.Length) {
        if ($source[$end] -eq '{') { $depth++ }
        if ($source[$end] -eq '}') { $depth-- }
        $end++
    }
    if ($depth -ne 0) { throw "Unbalanced method: $signature" }
    return $source.Substring($start, $end - $start).Replace('private void PauseFailed', 'public void PauseFailed')
}
$queue = Get-Content (Join-Path $PSScriptRoot '../../GatherBuddy/Crafting/CraftingQueueProcessor.cs') -Raw
$plan = Get-Content (Join-Path $PSScriptRoot '../../GatherBuddy/Crafting/CraftingExecutionPlan.cs') -Raw
$methods = 'partial class QueueHarness {' + (Get-Method $queue 'private void PauseFailedRaphaelItem(') + (Get-Method $queue 'public void Resume()') + '}'
$methods += 'partial class QueueHarness {' + (Get-Method $queue 'private void ProcessTasks()').Replace('private void ProcessTasks', 'public void ProcessTasks') + (Get-Method $queue 'private void PauseForRepair(').Replace('private void PauseForRepair', 'public void PauseForRepair') + (Get-Method $queue 'private void TransitionFromRepairComplete()').Replace('private void TransitionFromRepairComplete', 'public void TransitionFromRepairComplete') + '}'
$repair = Get-Method $queue 'private unsafe void QueueRepairTasks()'
if ($repair.Contains('CompleteQueue()') -or -not $repair.Contains('PauseForRepair(BuildRepairPauseReason())')) { throw 'Unavailable repair must pause, never complete.' }
$status = Get-Content (Join-Path $PSScriptRoot '../../GatherBuddy/Gui/CraftingStatusWindow.cs') -Raw
if (-not $status.Contains('for (var i = activity.Count - 1; i >= start; i--)')) { throw 'Recent activity must be newest first after fork patches.' }
$methods += 'partial class PlanHarness {' + (Get-Method $plan 'public void RefreshRemainingFromCurrentInventory(') + '}'
$interop = Get-Content (Join-Path $PSScriptRoot '../../GatherBuddy/Crafting/CraftingGameInterop.cs') -Raw
$methods += 'partial class SelectionHarness {' + (Get-Method $interop 'private static unsafe bool EnsureExpectedRecipeSelected()').Replace('private static unsafe bool', 'public static unsafe bool') + '}'
New-Item -ItemType Directory (Join-Path $PSScriptRoot 'obj') -Force | Out-Null
Set-Content (Join-Path $PSScriptRoot 'obj/QueueMethods.g.cs') $methods -Encoding utf8
& dotnet run --project $PSScriptRoot -c Release
if ($LASTEXITCODE -ne 0) { throw 'Craft blocker regression tests failed.' }
