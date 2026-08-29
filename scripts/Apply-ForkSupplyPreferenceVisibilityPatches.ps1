$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Content.Contains($Old)) {
        throw "Could not apply supply-source visibility patch '$Label'. Earlier fork patches or upstream source changed."
    }

    return $Content.Replace($Old, $New)
}

# This pass runs after Apply-ForkSupplyPreferencePatches.ps1 has generated the
# preference selector. The selected strategy must be authoritative in the UI:
# GatherFirst hides every vendor suggestion, while VendorFirst exposes vendor
# shopping and still gathers materials that have no vendor source.

$supportPath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\ForkVulcanWorkflowSupport.cs'
$support = Get-Content -LiteralPath $supportPath -Raw

$support = Replace-Required $support @'
        if (blocker.Source == MaterialSource.GilVendor || ForkVulcanSupplyPlan.IsGilVendorAvailable(blocker.ItemId))
'@ @'
        if (blocker.Source == MaterialSource.GilVendor || ForkVulcanSupplyPlan.ShouldUseVendor(blocker.ItemId))
'@ 'hide vendor hints while GatherFirst is selected'

Set-Content -LiteralPath $supportPath -Value $support -Encoding utf8 -NoNewline

$statusPath = Join-Path $PSScriptRoot '..\GatherBuddy\Gui\CraftingStatusWindow.cs'
$status = Get-Content -LiteralPath $statusPath -Raw

$status = Replace-Required $status @'
        ImGui.TextDisabled("Dual-source materials always show both options. Changes apply on the next material re-plan / Resume.");
'@ @'
        ImGui.TextDisabled("This choice is saved for future runs. The active sources below update immediately; Resume/re-plan applies it to automation.");
        ImGui.TextColored(
            new System.Numerics.Vector4(0.72f, 0.82f, 0.92f, 1.0f),
            preference == VulcanSupplyPreference.GatherFirst
                ? "Active sources: gathering + manual acquisition. Vendor suggestions are hidden."
                : "Active sources: gil vendors first, then gathering for anything vendors cannot supply.");
'@ 'show active persisted source strategy directly below selector'

$status = Replace-Required $status @'
            if (!target.Complete && ForkVulcanSupplyPlan.HasDualSource(target.ItemId))
            {
                var vendorAlternative = ForkVulcanSupplyPlan.GetVendorAlternativeHint(target.ItemId, target.Remaining);
                if (!string.IsNullOrWhiteSpace(vendorAlternative))
                {
                    ImGui.PushTextWrapPos();
                    ImGui.TextColored(
                        new System.Numerics.Vector4(0.95f, 0.82f, 0.45f, 1.0f),
                        $"    Vendor alternative: {vendorAlternative}");
                    ImGui.PopTextWrapPos();
                }
            }
'@ @'
'@ 'remove inactive vendor alternatives from gather view'

$status = Replace-Required $status @'
    private static void DrawVendorSupplyStops(CraftingQueueProcessor.QueueState currentState)
    {
        if (currentState != CraftingQueueProcessor.QueueState.WaitingForManualMaterials)
'@ @'
    private static void DrawVendorSupplyStops(CraftingQueueProcessor.QueueState currentState)
    {
        if (!ForkVulcanSupplyPlan.VendorsEnabled)
            return;

        if (currentState != CraftingQueueProcessor.QueueState.WaitingForManualMaterials)
'@ 'hide vendor shopping section unless VendorFirst is selected'

$status = Replace-Required $status @'
                if (ForkVulcanSupplyPlan.HasDualSource(purchase.ItemId))
                {
                    ImGui.TextColored(
                        new System.Numerics.Vector4(0.45f, 0.90f, 1.00f, 1.0f),
                        "        Free alternative: gatherable with BTN/MIN/FSH (switch to Gather first, then Resume/re-plan).");
                }
'@ @'
'@ 'remove inactive gathering alternatives from vendor view'

Set-Content -LiteralPath $statusPath -Value $status -Encoding utf8 -NoNewline
Write-Host 'Applied supply-source visibility patch: preference is persistent and only active sources are shown.'
