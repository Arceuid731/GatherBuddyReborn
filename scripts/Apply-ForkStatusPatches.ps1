$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Content.Contains($Old)) {
        throw "Could not apply status patch '$Label'. The base fork patch or upstream source changed."
    }
    return $Content.Replace($Old, $New)
}

# This script is intentionally run after Apply-ForkPatches.ps1. It polishes the
# fork-specific material workflow while keeping the main patch file easier to rebase.

# --- Queue state / retainer preflight --------------------------------------------
$queuePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingQueueProcessor.cs'
$queue = Get-Content -LiteralPath $queuePath -Raw

if ($queue -notmatch 'WaitingForManualMaterials') {
    $queue = Replace-Required $queue @'
        WithdrawingFromRetainer,
        WaitingForGather,
'@ @'
        WithdrawingFromRetainer,
        WaitingForGather,
        WaitingForManualMaterials,
'@ 'add manual-material state'

    $queue = Replace-Required $queue @'
        var hasRetainerWork = _retainerRestock && AllaganTools.Enabled
            && (MaterialTargets.Count > 0 || RetainerPrecraftTargets.Count > 0);
'@ @'
        var hasRetainerWork = _retainerRestock
            && ForkVulcanWorkflowSupport.HasUsefulRetainerWork(MaterialTargets, RetainerPrecraftTargets);
        if (_retainerRestock && !hasRetainerWork)
        {
            GatherBuddy.Log.Information("[CraftingQueueProcessor] Retainer restock enabled, but no current deficit can be satisfied by retainers; skipping bell navigation");
            ForkVulcanWorkflowSupport.AddActivity(
                "Retainer restock is enabled, but retainers have nothing useful for this craft; skipping the bell.",
                VulcanActivityKind.Retainer);
        }
'@ 'skip useless retainer trip'

    $queue = Replace-Required $queue @'
            case QueueState.WaitingForGather:
                break;
            case QueueState.WaitingForJobSwitch:
'@ @'
            case QueueState.WaitingForGather:
                break;
            case QueueState.WaitingForManualMaterials:
                break;
            case QueueState.WaitingForJobSwitch:
'@ 'manual-material update state'

    $queue = Replace-Required $queue @'
    public void Pause(string? reason = null)
    {
'@ @'
    public void PauseForManualMaterials(string reason)
    {
        // A blocker can be discovered while the old visible state still says
        // "Navigating to Retainer Bell". Stop that stale work and expose the real
        // phase before pausing so the UI and Resume behaviour stay coherent.
        _retainerBellNavigator?.Stop();
        _retainerBellNavigator = null;
        _tasks.Clear();
        _currentState = QueueState.WaitingForManualMaterials;
        StateChanged?.Invoke(_currentState);
        Pause(reason);
    }

    public void Pause(string? reason = null)
    {
'@ 'manual-material pause entry point'

    $queue = Replace-Required $queue @'
        if (_currentState == QueueState.WithdrawingFromRetainer)
        {
            GatherBuddy.Log.Debug("[CraftingQueueProcessor] Resuming retainer withdrawal");
            if (_retainerExecutor == null)
                QueueRetainerWithdrawalTasks();
            else
                QueueRetainerWithdrawalExecutionTasks();
            return;
        }
        
        if (_pausedDuringGather && _currentState == QueueState.WaitingForGather)
'@ @'
        if (_currentState == QueueState.WithdrawingFromRetainer)
        {
            GatherBuddy.Log.Debug("[CraftingQueueProcessor] Resuming retainer withdrawal");
            if (_retainerExecutor == null)
                QueueRetainerWithdrawalTasks();
            else
                QueueRetainerWithdrawalExecutionTasks();
            return;
        }

        if (_currentState == QueueState.WaitingForManualMaterials)
        {
            GatherBuddy.Log.Debug("[CraftingQueueProcessor] Manual materials resume requested; returning to material acquisition");
            _currentState = QueueState.WaitingForGather;
            StateChanged?.Invoke(_currentState);
            return;
        }
        
        if (_pausedDuringGather && _currentState == QueueState.WaitingForGather)
'@ 'resume manual-material pause'

    Set-Content -LiteralPath $queuePath -Value $queue -Encoding utf8 -NoNewline
    Write-Host 'Applied status patch: dedicated manual-material state and useful-retainer preflight.'
}
else {
    Write-Host 'Dedicated manual-material state already present.'
}

# --- Bridge: same retainer preflight, rich gather plan, coherent Resume -----------
$bridgePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingGatherBridge.cs'
$bridge = Get-Content -LiteralPath $bridgePath -Raw

if ($bridge -notmatch 'BuildGatherPlanSummary') {
    $bridge = Replace-Required $bridge @'
        var hasRetainerWork = executionPlan.RetainerRestock && AllaganTools.Enabled
            && (executionPlan.Materials.Count > 0 || executionPlan.RetainerConsumedCraftables.Count > 0);
'@ @'
        var hasRetainerWork = executionPlan.RetainerRestock
            && ForkVulcanWorkflowSupport.HasUsefulRetainerWork(
                executionPlan.Materials,
                executionPlan.RetainerConsumedCraftables);
'@ 'bridge useful-retainer preflight'

    $bridge = Replace-Required $bridge @'
            var manualBlockers = ForkVulcanWorkflowSupport.UpdateManualBlockers(
                missing,
                _activeExecutionPlan?.RetainerRestock == true);
            if (_gatherList.Items.Count > 0)
            {
                ForkVulcanWorkflowSupport.AddActivity(
                    $"Automatic gathering planned for {_gatherList.Items.Count} material type(s).",
                    VulcanActivityKind.Gather);
            }
'@ @'
            ForkVulcanWorkflowSupport.UpdateGatherTargets(
                _gatherList.Items.Select(item => (item.ItemId, (int)_gatherList.Quantities[item])));

            var manualBlockers = ForkVulcanWorkflowSupport.UpdateManualBlockers(
                missing,
                _activeExecutionPlan?.RetainerRestock == true);
            if (_gatherList.Items.Count > 0)
            {
                var gatherSummary = ForkVulcanWorkflowSupport.BuildGatherPlanSummary();
                ForkVulcanWorkflowSupport.AddActivity(
                    string.IsNullOrWhiteSpace(gatherSummary)
                        ? $"Automatic gathering planned for {_gatherList.Items.Count} material type(s)."
                        : $"Gathering plan: {gatherSummary}.",
                    VulcanActivityKind.Gather);
            }
'@ 'record detailed gather targets'

    $bridge = Replace-Required $bridge @'
                    ForkVulcanWorkflowSupport.AddActivity(reason, VulcanActivityKind.Warning);
                    _queueProcessor.Pause(reason);
                    return;
'@ @'
                    ForkVulcanWorkflowSupport.ClearGatherTargets();
                    ForkVulcanWorkflowSupport.AddActivity(reason, VulcanActivityKind.Warning);
                    _queueProcessor.PauseForManualMaterials(reason);
                    return;
'@ 'pause in dedicated manual-material state'

    $bridge = Replace-Required $bridge @'
            ForkVulcanWorkflowSupport.ClearManualBlockers();
            ForkVulcanWorkflowSupport.AddActivity("All required materials are in the inventory; continuing to crafting.", VulcanActivityKind.Success);
'@ @'
            ForkVulcanWorkflowSupport.ClearGatherTargets();
            ForkVulcanWorkflowSupport.ClearManualBlockers();
            ForkVulcanWorkflowSupport.AddActivity("All required materials are in the inventory; continuing to crafting.", VulcanActivityKind.Success);
'@ 'clear gather plan after acquisition'

    $bridge = Replace-Required $bridge @'
        var resumeMaterialCheck = _queueProcessor.CurrentState == CraftingQueueProcessor.QueueState.WaitingForGather
                               && GetTemporaryGatherList() == null;
'@ @'
        var resumeMaterialCheck = (_queueProcessor.CurrentState == CraftingQueueProcessor.QueueState.WaitingForGather
                                || _queueProcessor.CurrentState == CraftingQueueProcessor.QueueState.WaitingForManualMaterials)
                               && GetTemporaryGatherList() == null;
'@ 'manual-state Resume recheck'

    Set-Content -LiteralPath $bridgePath -Value $bridge -Encoding utf8 -NoNewline
    Write-Host 'Applied status patch: detailed gather targets and material-aware Resume.'
}
else {
    Write-Host 'Detailed gather-plan bridge patch already present.'
}

# --- Crafting Status: live blockers + active gathering information ----------------
$statusPath = Join-Path $PSScriptRoot '..\GatherBuddy\Gui\CraftingStatusWindow.cs'
$status = Get-Content -LiteralPath $statusPath -Raw

if ($status -notmatch 'DrawGatherTargets\(') {
    if ($status -notmatch 'using System.Linq;') {
        $status = Replace-Required $status @'
using System.Collections.Generic;
'@ @'
using System.Collections.Generic;
using System.Linq;
'@ 'add LINQ import for live status'
    }

    $status = Replace-Required $status @'
        if (_queueProcessor.Paused && !string.IsNullOrWhiteSpace(_queueProcessor.PauseReason))
        {
            ImGui.PushTextWrapPos();
            ImGui.TextColored(new System.Numerics.Vector4(1.0f, 0.82f, 0.24f, 1.0f), _queueProcessor.PauseReason);
            ImGui.PopTextWrapPos();
        }
'@ @'
        if (_queueProcessor.Paused && !string.IsNullOrWhiteSpace(_queueProcessor.PauseReason))
        {
            var visiblePauseReason = currentState == CraftingQueueProcessor.QueueState.WaitingForManualMaterials
                ? ForkVulcanWorkflowSupport.BuildPauseReason(ForkVulcanWorkflowSupport.GetLiveManualBlockers())
                : _queueProcessor.PauseReason;
            ImGui.PushTextWrapPos();
            ImGui.TextColored(
                currentState == CraftingQueueProcessor.QueueState.WaitingForManualMaterials
                    && ForkVulcanWorkflowSupport.GetLiveManualBlockers().All(blocker => blocker.Complete)
                    ? new System.Numerics.Vector4(0.45f, 1.0f, 0.55f, 1.0f)
                    : new System.Numerics.Vector4(1.0f, 0.82f, 0.24f, 1.0f),
                visiblePauseReason);
            ImGui.PopTextWrapPos();
        }
'@ 'live pause reason'

    $status = Replace-Required $status @'
        DrawManualMaterialBlockers();

        if (ShouldShowRemainingEstimate(currentState))
'@ @'
        DrawGatherTargets(currentState);
        DrawManualMaterialBlockers(currentState);

        if (ShouldShowRemainingEstimate(currentState))
'@ 'render gather details before blockers'

    $status = Replace-Required $status @'
    private static void DrawManualMaterialBlockers()
    {
        var blockers = ForkVulcanWorkflowSupport.ManualBlockers;
        if (blockers.Count == 0)
            return;

        ImGui.Spacing();
        ImGui.Separator();
        ImGui.Spacing();
        ImGui.TextColored(new System.Numerics.Vector4(1.0f, 0.72f, 0.25f, 1.0f), "Manual materials required");
        ImGui.TextDisabled("Acquire/withdraw these items, then press Resume. Vulcan will re-check your bags.");

        const int maxBlockers = 6;
        for (var i = 0; i < blockers.Count && i < maxBlockers; i++)
        {
            var blocker = blockers[i];
            ImGui.TextColored(
                new System.Numerics.Vector4(1.0f, 0.55f, 0.45f, 1.0f),
                $"- {blocker.ItemName}: {blocker.Missing} missing ({blocker.Available}/{blocker.Needed} in bags)");

            foreach (var line in ForkVulcanWorkflowSupport.GetSourceHintLines(blocker))
            {
                ImGui.PushTextWrapPos();
                ImGui.TextColored(new System.Numerics.Vector4(0.72f, 0.76f, 0.82f, 1.0f), $"    {line}");
                ImGui.PopTextWrapPos();
            }
        }

        if (blockers.Count > maxBlockers)
            ImGui.TextDisabled($"...and {blockers.Count - maxBlockers} more material type(s).");
    }
'@ @'
    private static void DrawGatherTargets(CraftingQueueProcessor.QueueState currentState)
    {
        if (currentState != CraftingQueueProcessor.QueueState.WaitingForGather)
            return;

        var targets = ForkVulcanWorkflowSupport.GetGatherTargetStatus();
        if (targets.Count == 0)
            return;

        ImGui.Spacing();
        ImGui.Separator();
        ImGui.Spacing();
        ImGui.TextColored(new System.Numerics.Vector4(0.45f, 0.90f, 1.0f, 1.0f), "Gathering materials");

        const int maxTargets = 8;
        for (var i = 0; i < targets.Count && i < maxTargets; i++)
        {
            var target = targets[i];
            var color = target.Complete
                ? new System.Numerics.Vector4(0.45f, 1.0f, 0.55f, 1.0f)
                : new System.Numerics.Vector4(0.82f, 0.88f, 1.0f, 1.0f);
            var suffix = target.Complete
                ? "ready"
                : $"{target.Remaining} remaining";
            ImGui.TextColored(color, $"- {target.ItemName}: {target.CurrentQuantity}/{target.TargetQuantity} ({suffix})");
        }

        if (targets.Count > maxTargets)
            ImGui.TextDisabled($"...and {targets.Count - maxTargets} more material type(s).");
    }

    private static void DrawManualMaterialBlockers(CraftingQueueProcessor.QueueState currentState)
    {
        if (currentState != CraftingQueueProcessor.QueueState.WaitingForManualMaterials)
            return;

        var blockers = ForkVulcanWorkflowSupport.GetLiveManualBlockers();
        if (blockers.Count == 0)
            return;

        var outstanding = blockers.Where(blocker => !blocker.Complete).ToList();
        ImGui.Spacing();
        ImGui.Separator();
        ImGui.Spacing();

        if (outstanding.Count == 0)
        {
            ImGui.TextColored(new System.Numerics.Vector4(0.45f, 1.0f, 0.55f, 1.0f), "Manual materials acquired");
            ImGui.TextDisabled("All blocked materials are now in your bags. Press Resume to continue.");
            foreach (var blocker in blockers.Take(6))
                ImGui.TextColored(new System.Numerics.Vector4(0.45f, 1.0f, 0.55f, 1.0f), $"- {blocker.ItemName}: {blocker.Available}/{blocker.Needed} ready");
            return;
        }

        ImGui.TextColored(new System.Numerics.Vector4(1.0f, 0.72f, 0.25f, 1.0f), "Manual materials required");
        ImGui.TextDisabled("Acquire/withdraw these items, then press Resume. Counts update live.");

        const int maxBlockers = 6;
        foreach (var blocker in outstanding.Take(maxBlockers))
        {
            ImGui.TextColored(
                new System.Numerics.Vector4(1.0f, 0.55f, 0.45f, 1.0f),
                $"- {blocker.ItemName}: {blocker.Missing} missing ({blocker.Available}/{blocker.Needed} in bags)");

            foreach (var line in ForkVulcanWorkflowSupport.GetSourceHintLines(blocker))
            {
                ImGui.PushTextWrapPos();
                ImGui.TextColored(new System.Numerics.Vector4(0.72f, 0.76f, 0.82f, 1.0f), $"    {line}");
                ImGui.PopTextWrapPos();
            }
        }

        if (outstanding.Count > maxBlockers)
            ImGui.TextDisabled($"...and {outstanding.Count - maxBlockers} more material type(s).");
    }
'@ 'live blocker and gather panels'

    $status = Replace-Required $status @'
            CraftingQueueProcessor.QueueState.WithdrawingFromRetainer => "Withdrawing from Retainers",
            CraftingQueueProcessor.QueueState.WaitingForGather => "Gathering Materials",
'@ @'
            CraftingQueueProcessor.QueueState.WithdrawingFromRetainer => "Withdrawing from Retainers",
            CraftingQueueProcessor.QueueState.WaitingForGather => "Gathering Materials",
            CraftingQueueProcessor.QueueState.WaitingForManualMaterials => "Waiting for Manual Materials",
'@ 'manual-material display name'

    Set-Content -LiteralPath $statusPath -Value $status -Encoding utf8 -NoNewline
    Write-Host 'Applied status patch: live blockers and detailed gathering information.'
}
else {
    Write-Host 'Live Vulcan status patch already present.'
}
