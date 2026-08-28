$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Content.Contains($Old)) {
        throw "Could not apply supply-preference patch '$Label'. An earlier fork patch or upstream source changed."
    }

    return $Content.Replace($Old, $New)
}

# Runs after Apply-ForkSupplyPlanPatches.ps1. The previous pass introduced vendor
# grouping; this pass makes vendor-vs-gather a user preference instead of an
# unconditional vendor override. GatherFirst is deliberately the safe/default mode.

# --- Persisted preference ----------------------------------------------------------
$configPath = Join-Path $PSScriptRoot '..\GatherBuddy\Config\Configuration.cs'
$config = Get-Content -LiteralPath $configPath -Raw

if ($config -notmatch 'VulcanSupplyPreference\s+VulcanSupplyPreference') {
    $config = Replace-Required $config @'
    public bool   VendorNpcLocationsDataShareFirst { get; set; } = true;
'@ @'
    public bool   VendorNpcLocationsDataShareFirst { get; set; } = true;
    public VulcanSupplyPreference VulcanSupplyPreference { get; set; } = VulcanSupplyPreference.GatherFirst;
'@ 'persist supply preference with gather-first default'

    Set-Content -LiteralPath $configPath -Value $config -Encoding utf8 -NoNewline
    Write-Host 'Applied supply-preference patch: persisted GatherFirst/VendorFirst choice.'
}
else {
    Write-Host 'Supply preference config already present.'
}

# --- Acquisition classification ---------------------------------------------------
$supportPath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\ForkVulcanWorkflowSupport.cs'
$support = Get-Content -LiteralPath $supportPath -Raw

if ($support -match 'ForkVulcanSupplyPlan\.IsGilVendorPreferred') {
    $support = Replace-Required $support @'
        // If the item is sold for gil, treat that as the preferred acquisition
        // source even when the same item also has a gathering node. This prevents
        // wasteful travel for trivial vendor mats and lets all purchases be grouped.
        if (ForkVulcanSupplyPlan.IsGilVendorPreferred(itemId))
            return MaterialSource.GilVendor;
'@ @'
        // Vendor availability is an alternative, not a forced override. Vendor-only
        // items still use the vendor; dual-source items follow the user's preference.
        if (ForkVulcanSupplyPlan.ShouldUseVendor(itemId))
            return MaterialSource.GilVendor;
'@ 'respect gather-vs-vendor preference during classification'

    $support = $support.Replace(
        'blocker.Source == MaterialSource.GilVendor || ForkVulcanSupplyPlan.IsGilVendorPreferred(blocker.ItemId)',
        'blocker.Source == MaterialSource.GilVendor || ForkVulcanSupplyPlan.IsGilVendorAvailable(blocker.ItemId)')

    Set-Content -LiteralPath $supportPath -Value $support -Encoding utf8 -NoNewline
    Write-Host 'Applied supply-preference patch: acquisition classification now respects user choice.'
}
else {
    Write-Host 'Choice-aware acquisition classification already present.'
}

# --- Crafting bridge ---------------------------------------------------------------
$bridgePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingGatherBridge.cs'
$bridge = Get-Content -LiteralPath $bridgePath -Raw

if ($bridge -match 'ForkVulcanSupplyPlan\.IsGilVendorPreferred\(gatherItemId\)') {
    $bridge = $bridge.Replace(
        'ForkVulcanSupplyPlan.IsGilVendorPreferred(gatherItemId)',
        'ForkVulcanSupplyPlan.ShouldUseVendor(gatherItemId)')
    $bridge = $bridge.Replace(
        'Deferring item {gatherItemId} to grouped vendor shopping instead of AutoGather',
        'Deferring item {gatherItemId} to grouped vendor shopping according to supply preference')

    Set-Content -LiteralPath $bridgePath -Value $bridge -Encoding utf8 -NoNewline
    Write-Host 'Applied supply-preference patch: bridge chooses vendor or gathering from preference.'
}
else {
    Write-Host 'Choice-aware bridge already present.'
}

# --- Crafting Status: preference selector + always-visible alternatives ------------
$statusPath = Join-Path $PSScriptRoot '..\GatherBuddy\Gui\CraftingStatusWindow.cs'
$status = Get-Content -LiteralPath $statusPath -Raw

if ($status -notmatch 'DrawSupplyPreference\(') {
    $status = Replace-Required $status @'
        DrawGatherTargets(currentState);
        DrawVendorSupplyStops(currentState);
        DrawManualMaterialBlockers(currentState);
'@ @'
        DrawSupplyPreference(currentState);
        DrawGatherTargets(currentState);
        DrawVendorSupplyStops(currentState);
        DrawManualMaterialBlockers(currentState);
'@ 'render supply preference before acquisition details'

    $status = Replace-Required $status @'
            ImGui.TextColored(color, $"- {target.ItemName}: {target.CurrentQuantity}/{target.TargetQuantity} ({suffix}){retainerSuffix}");
'@ @'
            ImGui.TextColored(color, $"- {target.ItemName}: {target.CurrentQuantity}/{target.TargetQuantity} ({suffix}){retainerSuffix}");
            if (!target.Complete && ForkVulcanSupplyPlan.HasDualSource(target.ItemId))
            {
                var vendorAlternative = ForkVulcanSupplyPlan.GetVendorAlternativeHint(target.ItemId, target.Remaining);
                if (!string.IsNullOrWhiteSpace(vendorAlternative))
                {
                    ImGui.PushTextWrapPos();
                    ImGui.TextColored(
                        new System.Numerics.Vector4(0.95f, 0.82f, 0.45f, 1.0f),
                        $"    {vendorAlternative}");
                    ImGui.PopTextWrapPos();
                }
            }
'@ 'show vendor alternative beside gather target'

    $status = Replace-Required $status @'
    private static void DrawVendorSupplyStops(CraftingQueueProcessor.QueueState currentState)
    {
'@ @'
    private static void DrawSupplyPreference(CraftingQueueProcessor.QueueState currentState)
    {
        if (currentState != CraftingQueueProcessor.QueueState.NavigatingToRetainerBell
         && currentState != CraftingQueueProcessor.QueueState.WithdrawingFromRetainer
         && currentState != CraftingQueueProcessor.QueueState.WaitingForGather
         && currentState != CraftingQueueProcessor.QueueState.WaitingForManualMaterials)
            return;

        ImGui.Spacing();
        ImGui.Separator();
        ImGui.Spacing();
        ImGui.Text("Supply preference");

        var preference = ForkVulcanSupplyPlan.Preference;
        if (ImGui.RadioButton("Gather first (free)", preference == VulcanSupplyPreference.GatherFirst))
            ForkVulcanSupplyPlan.SetPreference(VulcanSupplyPreference.GatherFirst);
        ImGui.SameLine();
        if (ImGui.RadioButton("Vendors first (faster)", preference == VulcanSupplyPreference.VendorFirst))
            ForkVulcanSupplyPlan.SetPreference(VulcanSupplyPreference.VendorFirst);

        ImGui.TextDisabled("Dual-source materials always show both options. Changes apply on the next material re-plan / Resume.");
    }

    private static void DrawVendorSupplyStops(CraftingQueueProcessor.QueueState currentState)
    {
'@ 'add gather-vs-vendor selector'

    # Existing vendor grouping should only contain items selected for the vendor path.
    $status = $status.Replace(
        'ForkVulcanSupplyPlan.IsGilVendorPreferred(blocker.ItemId)',
        'ForkVulcanSupplyPlan.ShouldUseVendor(blocker.ItemId)')

    $status = Replace-Required $status @'
                if (purchase.RetainerAvailable > 0 && CraftingGatherBridge.GetActiveExecutionPlan()?.RetainerRestock != true)
                {
                    ImGui.TextColored(
                        new System.Numerics.Vector4(0.72f, 0.62f, 1.00f, 1.0f),
                        $"        Retainers: {purchase.RetainerAvailable} available (restock OFF)");
                }
'@ @'
                if (purchase.RetainerAvailable > 0 && CraftingGatherBridge.GetActiveExecutionPlan()?.RetainerRestock != true)
                {
                    ImGui.TextColored(
                        new System.Numerics.Vector4(0.72f, 0.62f, 1.00f, 1.0f),
                        $"        Retainers: {purchase.RetainerAvailable} available (restock OFF)");
                }

                if (ForkVulcanSupplyPlan.HasDualSource(purchase.ItemId))
                {
                    ImGui.TextColored(
                        new System.Numerics.Vector4(0.45f, 0.90f, 1.00f, 1.0f),
                        "        Free alternative: gatherable with BTN/MIN/FSH (switch to Gather first, then Resume/re-plan).");
                }
'@ 'show free gathering alternative beside vendor purchase'

    Set-Content -LiteralPath $statusPath -Value $status -Encoding utf8 -NoNewline
    Write-Host 'Applied supply-preference patch: selector and dual-source alternatives in Crafting Status.'
}
else {
    Write-Host 'Supply preference UI already present.'
}
