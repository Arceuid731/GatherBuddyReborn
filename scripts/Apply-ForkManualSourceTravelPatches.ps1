$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [AllowEmptyString()][Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Content.Contains($Old)) {
        throw "Could not apply manual-source travel patch '$Label'. Earlier fork patches or upstream source changed."
    }

    return $Content.Replace($Old, $New)
}

# This pass intentionally runs LAST, after supply preference + visibility patches.
# It fixes the asymmetric VendorFirst -> GatherFirst live view by never trusting the
# source captured when a blocker was created, then adds explicit Go actions that use
# the existing VendorNavigator route engine while keeping the queue paused.

# --- Live source classification ---------------------------------------------------
$supportPath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\ForkVulcanWorkflowSupport.cs'
$support = Get-Content -LiteralPath $supportPath -Raw

if ($support -notmatch 'ForkVulcanMobSources\.GetEffectiveSource\(blocker\)') {
    $support = Replace-Required $support @'
        if (blocker.Source == MaterialSource.GilVendor || ForkVulcanSupplyPlan.ShouldUseVendor(blocker.ItemId))
        {
            lines.AddRange(ForkVulcanSupplyPlan.GetVendorHintLines(blocker));
            return lines;
        }

        // The mob cache initializes asynchronously. A location-less GatheringItem
        // can initially be classified as Other and become a known monster drop a
        // moment later, so resolve that dynamically for the UI.
        var dropInfo = MobDropInfoCache.GetDropInfoForItem(blocker.ItemId);
        var effectiveDrop = blocker.Source == MaterialSource.Drop || dropInfo.HasData;
        if (!effectiveDrop)
        {
            lines.Add(GetSourceLabel(blocker.Source));
            return lines;
        }
'@ @'
        var effectiveSource = ForkVulcanMobSources.GetEffectiveSource(blocker);
        if (effectiveSource == MaterialSource.GilVendor && ForkVulcanSupplyPlan.ShouldUseVendor(blocker.ItemId))
        {
            lines.AddRange(ForkVulcanSupplyPlan.GetVendorHintLines(blocker));
            return lines;
        }

        // Re-evaluate the source live. The blocker may have been created while
        // VendorFirst was selected, then the user can switch to GatherFirst while
        // paused. Mob-drop cache initialization is asynchronous as well.
        var dropInfo = MobDropInfoCache.GetDropInfoForItem(blocker.ItemId);
        var effectiveDrop = effectiveSource == MaterialSource.Drop || dropInfo.HasData;
        if (!effectiveDrop)
        {
            lines.Add(GetSourceLabel(effectiveSource));
            return lines;
        }
'@ 'reclassify blocker source live when supply preference changes'

    Set-Content -LiteralPath $supportPath -Value $support -Encoding utf8 -NoNewline
    Write-Host 'Applied manual-source travel patch: blocker sources now reclassify live.'
}
else {
    Write-Host 'Live blocker source reclassification already present.'
}

# --- Crafting Status: Go buttons for vendors and monster clusters -----------------
$statusPath = Join-Path $PSScriptRoot '..\GatherBuddy\Gui\CraftingStatusWindow.cs'
$status = Get-Content -LiteralPath $statusPath -Raw

if ($status -notmatch 'Go##mob-') {
    $status = Replace-Required $status @'
            ImGui.TextColored(
                new System.Numerics.Vector4(0.95f, 0.88f, 0.58f, 1.0f),
                $"{stop.NpcName} — {location}");
'@ @'
            if (ImGui.SmallButton($"Go##vendor-{stop.NpcId}"))
                ForkVulcanManualTravel.StartVendorTravel(stop);
            if (ImGui.IsItemHovered())
                ImGui.SetTooltip("Place a map flag and travel to this vendor. The crafting queue stays paused until you press Resume.");
            ImGui.SameLine();
            ImGui.TextColored(
                new System.Numerics.Vector4(0.95f, 0.88f, 0.58f, 1.0f),
                $"{stop.NpcName} — {location}");
'@ 'add Go action to grouped vendor stops'

    $status = Replace-Required $status @'
            foreach (var line in ForkVulcanWorkflowSupport.GetSourceHintLines(blocker))
            {
                ImGui.PushTextWrapPos();
                ImGui.TextColored(new System.Numerics.Vector4(0.72f, 0.76f, 0.82f, 1.0f), $"    {line}");
                ImGui.PopTextWrapPos();
            }
'@ @'
            var effectiveSource = ForkVulcanMobSources.GetEffectiveSource(blocker);
            if (effectiveSource == MaterialSource.Drop)
            {
                var restockDisabled = CraftingGatherBridge.GetActiveExecutionPlan()?.RetainerRestock != true;
                if (restockDisabled && blocker.RetainerAvailable > 0)
                {
                    ImGui.TextColored(
                        new System.Numerics.Vector4(0.72f, 0.62f, 1.00f, 1.0f),
                        $"    Retainers: {blocker.RetainerAvailable} available (Restock from Retainers is OFF).");
                }

                var locations = ForkVulcanMobSources.GetLocations(blocker.ItemId);
                if (locations.Count == 0)
                {
                    ImGui.TextDisabled(MobDropInfoCache.IsInitialized
                        ? "    Monster drop — no usable spawn coordinates are known."
                        : "    Monster drop — spawn data is still loading...");
                }
                else
                {
                    foreach (var mobLocation in locations)
                    {
                        if (mobLocation.HasCoordinates)
                        {
                            if (ImGui.SmallButton($"Go##mob-{blocker.ItemId}-{mobLocation.BNpcNameId}-{mobLocation.TerritoryTypeId}-{mobLocation.MapX:F1}-{mobLocation.MapY:F1}"))
                                ForkVulcanManualTravel.StartMobTravel(mobLocation, blocker.Missing);
                            if (ImGui.IsItemHovered())
                                ImGui.SetTooltip("Place a map flag, teleport and navigate to this mob spawn. Farm manually, then press Resume when you are ready.");
                            ImGui.SameLine();
                            ImGui.TextColored(
                                new System.Numerics.Vector4(0.72f, 0.82f, 0.92f, 1.0f),
                                $"{mobLocation.MobName} — {mobLocation.ZoneName} (X {mobLocation.MapX:F1}, Y {mobLocation.MapY:F1})");
                        }
                        else
                        {
                            ImGui.TextColored(
                                new System.Numerics.Vector4(0.72f, 0.82f, 0.92f, 1.0f),
                                $"    {mobLocation.MobName} — {mobLocation.ZoneName}");
                        }
                    }
                }
            }
            else if (effectiveSource is MaterialSource.Gatherable or MaterialSource.Fish)
            {
                var restockDisabled = CraftingGatherBridge.GetActiveExecutionPlan()?.RetainerRestock != true;
                if (restockDisabled && blocker.RetainerAvailable > 0)
                {
                    ImGui.TextColored(
                        new System.Numerics.Vector4(0.72f, 0.62f, 1.00f, 1.0f),
                        $"    Retainers: {blocker.RetainerAvailable} available (Restock from Retainers is OFF).");
                }
                ImGui.TextColored(
                    new System.Numerics.Vector4(0.45f, 0.90f, 1.00f, 1.0f),
                    "    Gathering source selected — press Resume to rebuild the automatic gathering step.");
            }
            else
            {
                foreach (var line in ForkVulcanWorkflowSupport.GetSourceHintLines(blocker))
                {
                    ImGui.PushTextWrapPos();
                    ImGui.TextColored(new System.Numerics.Vector4(0.72f, 0.76f, 0.82f, 1.0f), $"    {line}");
                    ImGui.PopTextWrapPos();
                }
            }
'@ 'render live mob locations with Go actions'

    $status = Replace-Required $status @'
        if (outstanding.Count > maxBlockers)
            ImGui.TextDisabled($"...and {outstanding.Count - maxBlockers} more material type(s).");
    }
'@ @'
        if (outstanding.Count > maxBlockers)
            ImGui.TextDisabled($"...and {outstanding.Count - maxBlockers} more material type(s).");

        if (!string.IsNullOrWhiteSpace(ForkVulcanManualTravel.StatusText))
        {
            ImGui.Spacing();
            ImGui.PushTextWrapPos();
            ImGui.TextColored(
                ForkVulcanManualTravel.IsActive
                    ? new System.Numerics.Vector4(0.45f, 0.90f, 1.00f, 1.0f)
                    : new System.Numerics.Vector4(0.55f, 0.90f, 0.62f, 1.0f),
                ForkVulcanManualTravel.StatusText);
            ImGui.PopTextWrapPos();
        }
    }
'@ 'show manual travel progress/arrival status'

    Set-Content -LiteralPath $statusPath -Value $status -Encoding utf8 -NoNewline
    Write-Host 'Applied manual-source travel patch: vendor and mob Go actions added.'
}
else {
    Write-Host 'Manual source Go actions already present.'
}

# --- Keep manual travel alive independently of the Crafting Status window ----------
$pluginPath = Join-Path $PSScriptRoot '..\GatherBuddy\GatherBuddy.cs'
$plugin = Get-Content -LiteralPath $pluginPath -Raw

if ($plugin -notmatch 'ForkVulcanManualTravel\.Update\(\)') {
    $plugin = Replace-Required $plugin @'
            VendorPurchaseManager.Update();
            VendorBuyListManager.Update();
'@ @'
            VendorPurchaseManager.Update();
            VendorBuyListManager.Update();
            ForkVulcanManualTravel.Update();
'@ 'update manual travel every framework frame'

    $plugin = Replace-Required $plugin @'
        VendorBuyListManager?.Dispose();
        VendorPurchaseManager?.Dispose();
'@ @'
        ForkVulcanManualTravel.Stop(clearStatus: true);
        VendorBuyListManager?.Dispose();
        VendorPurchaseManager?.Dispose();
'@ 'stop manual travel on plugin disposal'

    Set-Content -LiteralPath $pluginPath -Value $plugin -Encoding utf8 -NoNewline
    Write-Host 'Applied manual-source travel patch: framework update/disposal integration added.'
}
else {
    Write-Host 'Manual travel framework integration already present.'
}

# --- Resume/Stop are explicit manual-step boundaries -------------------------------
$bridgePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingGatherBridge.cs'
$bridge = Get-Content -LiteralPath $bridgePath -Raw

if ($bridge -notmatch 'ForkVulcanManualTravel\.Stop\(clearStatus: false\)') {
    $bridge = [regex]::Replace(
        $bridge,
        '(public\s+static\s+void\s+ResumeQueue\(\)\s*\{\s*)',
        '$1' + "`n        ForkVulcanManualTravel.Stop(clearStatus: false);`n",
        1)
    if ($bridge -notmatch 'ForkVulcanManualTravel\.Stop\(clearStatus: false\)') {
        throw "Could not apply manual-source travel patch 'stop travel on Resume'."
    }
}

if ($bridge -notmatch 'ForkVulcanManualTravel\.Stop\(clearStatus: true\)') {
    $bridge = [regex]::Replace(
        $bridge,
        '(public\s+static\s+void\s+StopQueue\(\)\s*\{\s*)',
        '$1' + "`n        ForkVulcanManualTravel.Stop(clearStatus: true);`n",
        1)
    if ($bridge -notmatch 'ForkVulcanManualTravel\.Stop\(clearStatus: true\)') {
        throw "Could not apply manual-source travel patch 'stop travel on queue Stop'."
    }
}

Set-Content -LiteralPath $bridgePath -Value $bridge -Encoding utf8 -NoNewline
Write-Host 'Applied manual-source travel patch: Resume/Stop own manual travel lifecycle.'
