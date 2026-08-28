$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Content.Contains($Old)) {
        throw "Could not apply gather-loop patch '$Label'. The base/status fork patch or upstream source changed."
    }

    return $Content.Replace($Old, $New)
}

# This script runs after Apply-ForkPatches.ps1 and Apply-ForkStatusPatches.ps1.
# It fixes a nasty interaction found in-game:
#
# - GameData.Gatherables is sourced from the game's GatheringItem sheet.
# - Some GatheringItem rows exist without any real GatheringNode location.
# - The old crafting bridge treated ContainsKey(itemId) as proof AutoGather could
#   obtain the item and generated a list containing those phantom gatherables.
# - AutoGather immediately stopped/honked, OnGatherComplete saw the same deficit,
#   rebuilt the list, and repeated forever.
#
# Only items with a concrete node/fishing spot are now sent to AutoGather. The
# recovery path is also bounded so a future data/plugin failure can never create
# an infinite rebuild/honk loop again.

$bridgePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingGatherBridge.cs'
$bridge = Get-Content -LiteralPath $bridgePath -Raw

if ($bridge -notmatch 'TryAddAutoGatherTarget\(_gatherList') {
    $bridge = Replace-Required $bridge @'
                if (GatherBuddy.GameData.Gatherables.TryGetValue(gatherItemId, out var gatherable))
                    _gatherList.Add(gatherable, (uint)gatherQuantity);
                else if (GatherBuddy.GameData.Fishes.TryGetValue(gatherItemId, out var fish))
                    _gatherList.Add(fish, (uint)gatherQuantity);
                else
                    GatherBuddy.Log.Debug($"[CraftingGatherBridge] Item {gatherItemId} not found in gatherables or fish, deferring to manual-material guard");
'@ @'
                if (!ForkVulcanWorkflowSupport.TryAddAutoGatherTarget(_gatherList, gatherItemId, gatherQuantity))
                {
                    var source = ForkVulcanWorkflowSupport.ClassifyForAcquisition(gatherItemId);
                    GatherBuddy.Log.Debug(
                        $"[CraftingGatherBridge] Item {gatherItemId} is not a real AutoGather node/spot target (source={source}); deferring to manual-material guard");
                }
'@ 'require a real node or fishing spot for crafting AutoGather'

    $bridge = Replace-Required $bridge @'
                if (ForkVulcanWorkflowSupport.HasOutstandingGatherables(remainingMaterials))
                {
                    var gatherableCount = ForkVulcanWorkflowSupport.CountOutstandingGatherables(remainingMaterials);
                    GatherBuddy.Log.Warning($"[CraftingGatherBridge] Gather completion fired with {gatherableCount} gatherable material type(s) still missing; rebuilding the gather stage");
                    ForkVulcanWorkflowSupport.AddActivity(
                        $"Gather stage still has {gatherableCount} material type(s) missing; rebuilding AutoGather instead of crafting early.",
                        VulcanActivityKind.Warning);
                    CreateGatherListForMissingIngredients(remainingMaterials);
                    return;
                }
'@ @'
                if (ForkVulcanWorkflowSupport.HasOutstandingGatherables(remainingMaterials))
                {
                    var gatherableCount = ForkVulcanWorkflowSupport.CountOutstandingGatherables(remainingMaterials);
                    if (ForkVulcanWorkflowSupport.TryRegisterGatherRecovery(
                            remainingMaterials,
                            out var outstandingSummary,
                            out var stopReason))
                    {
                        GatherBuddy.Log.Warning(
                            $"[CraftingGatherBridge] Gather completion fired with {gatherableCount} real gatherable material type(s) still missing; performing one bounded recovery pass: {outstandingSummary}");
                        ForkVulcanWorkflowSupport.AddActivity(
                            $"AutoGather ended early; retrying the remaining gather plan once: {outstandingSummary}.",
                            VulcanActivityKind.Warning);
                        CreateGatherListForMissingIngredients(remainingMaterials);
                        return;
                    }

                    // Never repeatedly re-enable AutoGather after an unchanged
                    // completion/error. Besides wasting CPU/logs this triggers the
                    // plugin's embedded honk on every pass.
                    GatherBuddy.AutoGather.Enabled = false;
                    GatherBuddy.Log.Error($"[CraftingGatherBridge] {stopReason}");
                    ForkVulcanWorkflowSupport.AddActivity(stopReason, VulcanActivityKind.Error);
                    _queueProcessor.Pause(stopReason);
                    return;
                }
'@ 'bound gather recovery and stop honk loop'

    Set-Content -LiteralPath $bridgePath -Value $bridge -Encoding utf8 -NoNewline
    Write-Host 'Applied gather-loop patch: real node/spot filtering and bounded AutoGather recovery.'
}
else {
    Write-Host 'Gather-loop guard patch already present.'
}
