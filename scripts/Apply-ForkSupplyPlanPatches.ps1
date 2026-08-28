$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Content.Contains($Old)) {
        throw "Could not apply supply-plan patch '$Label'. An earlier fork patch or upstream source changed."
    }

    return $Content.Replace($Old, $New)
}

# Runs after the existing fork patches. This adds a global acquisition policy for
# cheap gil-vendor materials: prefer one grouped shopping pass over gathering an
# item that can simply be bought, and expose seller/location/price in Crafting Status.

# --- Workflow support: vendor-first classification + rich vendor hints ------------
$supportPath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\ForkVulcanWorkflowSupport.cs'
$support = Get-Content -LiteralPath $supportPath -Raw

if ($support -notmatch 'ForkVulcanSupplyPlan.IsGilVendorPreferred') {
    $support = Replace-Required $support @'
    public static MaterialSource ClassifyForAcquisition(uint itemId)
    {
        if (GatherBuddy.GameData.Gatherables.TryGetValue(itemId, out var gatherable)
'@ @'
    public static MaterialSource ClassifyForAcquisition(uint itemId)
    {
        // If the item is sold for gil, treat that as the preferred acquisition
        // source even when the same item also has a gathering node. This prevents
        // wasteful travel for trivial vendor mats and lets all purchases be grouped.
        if (ForkVulcanSupplyPlan.IsGilVendorPreferred(itemId))
            return MaterialSource.GilVendor;

        if (GatherBuddy.GameData.Gatherables.TryGetValue(itemId, out var gatherable)
'@ 'prefer gil vendor before AutoGather classification'

    $support = Replace-Required $support @'
        if (blocker.RetainerAvailable > 0)
            lines.Add($"Retainers: {blocker.RetainerAvailable} available (enable Restock from Retainers or withdraw manually)." );

        // The mob cache initializes asynchronously. A location-less GatheringItem
'@ @'
        if (blocker.RetainerAvailable > 0)
            lines.Add($"Retainers: {blocker.RetainerAvailable} available (enable Restock from Retainers or withdraw manually)." );

        if (blocker.Source == MaterialSource.GilVendor || ForkVulcanSupplyPlan.IsGilVendorPreferred(blocker.ItemId))
        {
            lines.AddRange(ForkVulcanSupplyPlan.GetVendorHintLines(blocker));
            return lines;
        }

        // The mob cache initializes asynchronously. A location-less GatheringItem
'@ 'add vendor seller/location/price hints'

    Set-Content -LiteralPath $supportPath -Value $support -Encoding utf8 -NoNewline
    Write-Host 'Applied supply-plan patch: vendor-first classification and seller hints.'
}
else {
    Write-Host 'Supply-plan support patch already present.'
}

# --- Crafting bridge: do not AutoGather gil-vendor items; log grouped stops --------
$bridgePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingGatherBridge.cs'
$bridge = Get-Content -LiteralPath $bridgePath -Raw

if ($bridge -notmatch 'Deferring item .* to grouped vendor shopping') {
    $bridge = Replace-Required $bridge @'
                if (!ForkVulcanWorkflowSupport.TryAddAutoGatherTarget(_gatherList, gatherItemId, gatherQuantity))
                {
                    var source = ForkVulcanWorkflowSupport.ClassifyForAcquisition(gatherItemId);
                    GatherBuddy.Log.Debug(
                        $"[CraftingGatherBridge] Item {gatherItemId} is not a real AutoGather node/spot target (source={source}); deferring to manual-material guard");
                }
'@ @'
                if (ForkVulcanSupplyPlan.IsGilVendorPreferred(gatherItemId))
                {
                    GatherBuddy.Log.Debug(
                        $"[CraftingGatherBridge] Deferring item {gatherItemId} to grouped vendor shopping instead of AutoGather");
                }
                else if (!ForkVulcanWorkflowSupport.TryAddAutoGatherTarget(_gatherList, gatherItemId, gatherQuantity))
                {
                    var source = ForkVulcanWorkflowSupport.ClassifyForAcquisition(gatherItemId);
                    GatherBuddy.Log.Debug(
                        $"[CraftingGatherBridge] Item {gatherItemId} is not a real AutoGather node/spot target (source={source}); deferring to manual-material guard");
                }
'@ 'keep gil-vendor items out of AutoGather'

    $bridge = Replace-Required $bridge @'
            var manualBlockers = ForkVulcanWorkflowSupport.UpdateManualBlockers(
                missing,
                _activeExecutionPlan?.RetainerRestock == true);
            if (_gatherList.Items.Count > 0)
'@ @'
            var manualBlockers = ForkVulcanWorkflowSupport.UpdateManualBlockers(
                missing,
                _activeExecutionPlan?.RetainerRestock == true);

            var vendorPlanSummary = ForkVulcanSupplyPlan.BuildVendorPlanSummary(manualBlockers);
            if (!string.IsNullOrWhiteSpace(vendorPlanSummary))
            {
                ForkVulcanWorkflowSupport.AddActivity(
                    $"Grouped vendor shopping: {vendorPlanSummary}.",
                    VulcanActivityKind.Info);
            }

            if (_gatherList.Items.Count > 0)
'@ 'log grouped vendor plan'

    Set-Content -LiteralPath $bridgePath -Value $bridge -Encoding utf8 -NoNewline
    Write-Host 'Applied supply-plan patch: grouped vendor shopping before AutoGather.'
}
else {
    Write-Host 'Supply-plan bridge patch already present.'
}

# --- Crafting Status: grouped shopping stops --------------------------------------
$statusPath = Join-Path $PSScriptRoot '..\GatherBuddy\Gui\CraftingStatusWindow.cs'
$status = Get-Content -LiteralPath $statusPath -Raw

if ($status -notmatch 'DrawVendorSupplyStops\(') {
    $status = Replace-Required $status @'
        DrawGatherTargets(currentState);
        DrawManualMaterialBlockers(currentState);
'@ @'
        DrawGatherTargets(currentState);
        DrawVendorSupplyStops(currentState);
        DrawManualMaterialBlockers(currentState);
'@ 'render grouped vendor stops'

    $status = Replace-Required $status @'
    private static void DrawManualMaterialBlockers(CraftingQueueProcessor.QueueState currentState)
    {
'@ @'
    private static void DrawVendorSupplyStops(CraftingQueueProcessor.QueueState currentState)
    {
        if (currentState != CraftingQueueProcessor.QueueState.WaitingForManualMaterials)
            return;

        var blockers = ForkVulcanWorkflowSupport.GetLiveManualBlockers();
        if (!blockers.Any(blocker => !blocker.Complete && ForkVulcanSupplyPlan.IsGilVendorPreferred(blocker.ItemId)))
            return;

        var stops = ForkVulcanSupplyPlan.BuildVendorStops(blockers);
        ImGui.Spacing();
        ImGui.Separator();
        ImGui.Spacing();
        ImGui.TextColored(new System.Numerics.Vector4(0.95f, 0.82f, 0.35f, 1.0f), "Vendor shopping stops");
        ImGui.TextDisabled("Buy every listed material at a stop before moving on. Quantities update live.");

        if (stops.Count == 0)
        {
            ImGui.TextDisabled(ForkVulcanSupplyPlan.VendorDataLoading
                ? "Vendor/location data is still loading..."
                : "Vendor data is available, but no usable seller/location could be resolved yet.");
            return;
        }

        const int maxStops = 5;
        foreach (var stop in stops.Take(maxStops))
        {
            var location = stop.MapX.HasValue && stop.MapY.HasValue
                ? $"{stop.ZoneName} (X {stop.MapX.Value:F1}, Y {stop.MapY.Value:F1})"
                : stop.ZoneName;
            ImGui.TextColored(
                new System.Numerics.Vector4(0.95f, 0.88f, 0.58f, 1.0f),
                $"{stop.NpcName} — {location}");

            foreach (var purchase in stop.Purchases)
            {
                var price = purchase.Missing > 1
                    ? $"{purchase.UnitCost:N0} {purchase.CurrencyName}/ea, {purchase.TotalCost:N0} total"
                    : $"{purchase.UnitCost:N0} {purchase.CurrencyName}";
                ImGui.TextColored(
                    new System.Numerics.Vector4(0.82f, 0.86f, 0.92f, 1.0f),
                    $"    - {purchase.ItemName}: buy {purchase.Missing} ({price})");
            }
        }

        if (stops.Count > maxStops)
            ImGui.TextDisabled($"...and {stops.Count - maxStops} more vendor stop(s).");
    }

    private static void DrawManualMaterialBlockers(CraftingQueueProcessor.QueueState currentState)
    {
'@ 'add grouped vendor shopping UI'

    Set-Content -LiteralPath $statusPath -Value $status -Encoding utf8 -NoNewline
    Write-Host 'Applied supply-plan patch: grouped vendor shopping status UI.'
}
else {
    Write-Host 'Grouped vendor shopping status UI already present.'
}
