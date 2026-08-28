$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Content.Contains($Old)) {
        throw "Could not apply fork patch '$Label'. Upstream likely changed; review scripts/Apply-ForkPatches.ps1."
    }

    return $Content.Replace($Old, $New)
}

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

# --- Vulcan material acquisition recovery ----------------------------------------
# Keep the execution flow deterministic for crafting queues:
#   optional retainer restock -> gather every BTN/MIN/FSH leaf -> pause for manual
#   materials (drops/vendors/etc.) -> Resume rechecks inventory -> craft.
# The temporary crafting gather list must be isolated from *all* user lists,
# including fallback lists: an invalid fallback fish entry can otherwise prevent
# AutoGather from starting and make Vulcan jump straight into crafting.
$bridgePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingGatherBridge.cs'
$bridgeContent = Get-Content -LiteralPath $bridgePath -Raw

if ($bridgeContent -notmatch 'ForkVulcanWorkflowSupport\.Reset\(\)') {
    $old = @'
        _waitingForGatherComplete = true;
        GatherBuddy.Log.Information($"[CraftingGatherBridge] Starting queue automation with {executionPlan.QueueView.Count} recipes, retainerRestock={executionPlan.RetainerRestock}");
        _queueProcessor.StartQueue(executionPlan, listConsumables, GatherBuddy.RaphaelSolveCoordinator);
'@
    $new = @'
        _waitingForGatherComplete = true;
        ForkVulcanWorkflowSupport.Reset();
        GatherBuddy.Log.Information($"[CraftingGatherBridge] Starting queue automation with {executionPlan.QueueView.Count} recipes, retainerRestock={executionPlan.RetainerRestock}");
        ForkVulcanWorkflowSupport.AddActivity(
            $"Queue started: {executionPlan.ListName} ({executionPlan.QueueView.Count} craft step(s)); retainer restock {(executionPlan.RetainerRestock ? "ON" : "OFF")}.",
            executionPlan.RetainerRestock ? VulcanActivityKind.Retainer : VulcanActivityKind.Info);
        _queueProcessor.StartQueue(executionPlan, listConsumables, GatherBuddy.RaphaelSolveCoordinator);
'@
    $bridgeContent = Replace-Required $bridgeContent $old $new 'queue activity initialization'

    $old = @'
        if (!hasRetainerWork)
            CreateGatherListForMissingIngredients(executionPlan.Materials);
'@
    $new = @'
        if (!hasRetainerWork)
        {
            ForkVulcanWorkflowSupport.AddActivity(
                executionPlan.RetainerRestock
                    ? "No retainer withdrawal is needed; resolving remaining materials."
                    : "Retainer restock is disabled; resolving materials from inventory and gathering.",
                VulcanActivityKind.Info);
            CreateGatherListForMissingIngredients(executionPlan.Materials);
        }
        else
        {
            ForkVulcanWorkflowSupport.AddActivity("Withdrawing available materials from retainers first.", VulcanActivityKind.Retainer);
        }
'@
    $bridgeContent = Replace-Required $bridgeContent $old $new 'retainer/gather planning activity'

    $old = @'
        try
        {
            if (_plugin != null)
            {
                var enabledLists = _plugin.AutoGatherListsManager.Lists.Where(l => l.Enabled && !l.Fallback).ToList();
'@
    $new = @'
        try
        {
            if (_gatherList != null)
                DeleteTemporaryGatherList();

            if (_plugin != null)
            {
                // A crafting run is an isolated acquisition plan. Disable every user
                // list, including fallback lists, so unrelated/invalid fish entries
                // cannot make AutoGather reject the generated crafting list.
                var enabledLists = _plugin.AutoGatherListsManager.Lists.Where(l => l.Enabled && l != _gatherList).ToList();
'@
    $bridgeContent = Replace-Required $bridgeContent $old $new 'isolate temporary crafting gather list'

    $old = @'
                else
                    GatherBuddy.Log.Debug($"[CraftingGatherBridge] Item {gatherItemId} not found in gatherables or fish, skipping");
            }

            if (_gatherList.Items.Count > 0 && _plugin != null)
'@
    $new = @'
                else
                    GatherBuddy.Log.Debug($"[CraftingGatherBridge] Item {gatherItemId} not found in gatherables or fish, deferring to manual-material guard");
            }

            var manualBlockers = ForkVulcanWorkflowSupport.UpdateManualBlockers(
                missing,
                _activeExecutionPlan?.RetainerRestock == true);
            if (_gatherList.Items.Count > 0)
            {
                ForkVulcanWorkflowSupport.AddActivity(
                    $"Automatic gathering planned for {_gatherList.Items.Count} material type(s).",
                    VulcanActivityKind.Gather);
            }
            if (manualBlockers.Count > 0)
            {
                ForkVulcanWorkflowSupport.AddActivity(
                    $"{manualBlockers.Count} manual material type(s) remain; Vulcan will pause after automatic gathering.",
                    VulcanActivityKind.Warning);
            }

            if (_gatherList.Items.Count > 0 && _plugin != null)
'@
    $bridgeContent = Replace-Required $bridgeContent $old $new 'classify manual blockers'

    $old = @'
                    _waitingForGatherComplete = true;
                    GatherBuddy.AutoGather.Enabled = true;
                    GatherBuddy.Log.Information($"Created crafting gather list with {_gatherList.Items.Count} items. Starting auto-gather.");
'@
    $new = @'
                    _waitingForGatherComplete = true;
                    GatherBuddy.AutoGather.Enabled = true;
                    if (!GatherBuddy.AutoGather.Enabled)
                    {
                        var reason = "AutoGather could not start the generated crafting-material list. Vulcan paused instead of skipping gathering. Check GatherBuddy validation messages, then press Resume.";
                        GatherBuddy.Log.Warning($"[CraftingGatherBridge] {reason}");
                        ForkVulcanWorkflowSupport.AddActivity(reason, VulcanActivityKind.Error);
                        _queueProcessor?.Pause(reason);
                        return;
                    }
                    GatherBuddy.Log.Information($"Created crafting gather list with {_gatherList.Items.Count} items. Starting auto-gather.");
                    ForkVulcanWorkflowSupport.AddActivity(
                        $"AutoGather started for {_gatherList.Items.Count} material type(s).",
                        VulcanActivityKind.Gather);
'@
    $bridgeContent = Replace-Required $bridgeContent $old $new 'verify AutoGather actually started'

    $old = @'
        catch (Exception ex)
        {
            GatherBuddy.Log.Error($"Failed to create gather list: {ex.Message}");
        }
    }
    
    public static void OnGatherComplete()
'@
    $new = @'
        catch (Exception ex)
        {
            var reason = $"Failed to prepare the crafting gather list: {ex.Message}";
            GatherBuddy.Log.Error($"[CraftingGatherBridge] {reason}");
            ForkVulcanWorkflowSupport.AddActivity(reason, VulcanActivityKind.Error);
            _queueProcessor?.Pause(reason);
        }
    }
    
    public static void OnGatherComplete()
'@
    $bridgeContent = Replace-Required $bridgeContent $old $new 'pause on gather-list construction failure'

    $old = @'
        if (_isQueueMode && _queueProcessor != null)
        {
            _waitingForGatherComplete = false;
            GatherBuddy.Log.Debug($"[CraftingGatherBridge] Gather complete for queue mode");
            _queueProcessor.OnGatherComplete();
            return;
        }
'@
    $new = @'
        if (_isQueueMode && _queueProcessor != null)
        {
            _waitingForGatherComplete = false;
            GatherBuddy.Log.Debug($"[CraftingGatherBridge] Gather completion reached for queue mode; validating material plan before crafting");
            DeleteTemporaryGatherList();

            if (_activeExecutionPlan != null)
            {
                // Re-plan from the *actual bag contents* after restock/gathering. This
                // makes the same guard work with retainer restock both ON and OFF.
                _activeExecutionPlan.RefreshFromCurrentInventory();
                var remainingMaterials = _activeExecutionPlan.Materials;

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

                var blockers = ForkVulcanWorkflowSupport.UpdateManualBlockers(
                    remainingMaterials,
                    _activeExecutionPlan.RetainerRestock);
                if (blockers.Count > 0)
                {
                    var reason = ForkVulcanWorkflowSupport.BuildPauseReason(blockers);
                    GatherBuddy.Log.Warning($"[CraftingGatherBridge] {reason}");
                    ForkVulcanWorkflowSupport.AddActivity(reason, VulcanActivityKind.Warning);
                    _queueProcessor.Pause(reason);
                    return;
                }
            }

            ForkVulcanWorkflowSupport.ClearManualBlockers();
            ForkVulcanWorkflowSupport.AddActivity("All required materials are in the inventory; continuing to crafting.", VulcanActivityKind.Success);
            _queueProcessor.OnGatherComplete();
            return;
        }
'@
    $bridgeContent = Replace-Required $bridgeContent $old $new 'validate materials before leaving gather stage'

    $old = @'
    public static void StopQueue()
    {
'@
    $new = @'
    public static void ResumeQueue()
    {
        if (_queueProcessor == null || !_queueProcessor.Paused)
            return;

        ForkVulcanWorkflowSupport.AddActivity("Resume requested; rechecking the current material plan.", VulcanActivityKind.Info);

        // A user-paused active gather keeps its generated list, so the queue's own
        // Resume() can simply restart AutoGather. A manual-material pause has no
        // temporary list: rebuild from current bags and either gather, pause again,
        // or continue to crafting.
        var resumeMaterialCheck = _queueProcessor.CurrentState == CraftingQueueProcessor.QueueState.WaitingForGather
                               && GetTemporaryGatherList() == null;
        _queueProcessor.Resume();

        if (resumeMaterialCheck && _activeExecutionPlan != null)
        {
            _activeExecutionPlan.RefreshFromCurrentInventory();
            CreateGatherListForMissingIngredients(_activeExecutionPlan.Materials);
        }
    }

    public static void StopQueue()
    {
'@
    $bridgeContent = Replace-Required $bridgeContent $old $new 'material-aware Resume entry point'

    $old = @'
    private static void OnQueueCompleted()
    {
        GatherBuddy.Log.Information("[CraftingGatherBridge] Queue completed, will clean up after tasks finish");
    }
'@
    $new = @'
    private static void OnQueueCompleted()
    {
        GatherBuddy.Log.Information("[CraftingGatherBridge] Queue completed, will clean up after tasks finish");
        ForkVulcanWorkflowSupport.ClearManualBlockers();
        ForkVulcanWorkflowSupport.AddActivity("Crafting queue complete.", VulcanActivityKind.Success);
    }
'@
    $bridgeContent = Replace-Required $bridgeContent $old $new 'queue completion activity'

    Set-Content -LiteralPath $bridgePath -Value $bridgeContent -Encoding utf8 -NoNewline
    Write-Host 'Applied fork patch: robust retainer/gather/manual-material acquisition flow.'
}
else {
    Write-Host 'Vulcan material acquisition recovery patch already present.'
}

# --- Missing-material craft recovery ---------------------------------------------
# Upstream retries RecipeNote assignment once and then silently skips the recipe.
# For the fork, a missing-material preparation failure returns to acquisition once;
# if it still fails after re-planning, pause visibly and let Resume re-check.
$queuePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingQueueProcessor.cs'
$queueContent = Get-Content -LiteralPath $queuePath -Raw

if ($queueContent -notmatch 'returning to material acquisition') {
    $old = @'
        if (priorFailures == 0)
        {
            _missingIngredientFailures[failure.RecipeId] = 1;
            GatherBuddy.Log.Warning($"[CraftingQueueProcessor] Missing materials caused {failureContext} failure for '{itemName}' (recipe {failure.RecipeId}): {failure.Details}. Retrying once before skipping remaining instances.");
            _currentState = QueueState.WaitingForJobSwitch;
            StateChanged?.Invoke(_currentState);
            return true;
        }
        GatherBuddy.Log.Warning($"[CraftingQueueProcessor] Missing materials caused {failureContext} to fail again for '{itemName}' (recipe {failure.RecipeId}): {failure.Details}. Skipping this and remaining instances of the recipe.");
        SkipRemainingRecipeInstances(failure.RecipeId);
        return true;
'@
    $new = @'
        if (priorFailures == 0)
        {
            _missingIngredientFailures[failure.RecipeId] = 1;
            GatherBuddy.Log.Warning($"[CraftingQueueProcessor] Missing materials caused {failureContext} failure for '{itemName}' (recipe {failure.RecipeId}): {failure.Details}. Re-planning and returning to material acquisition.");
            ForkVulcanWorkflowSupport.AddActivity(
                $"Craft preparation found missing materials for {itemName}; returning to material acquisition.",
                VulcanActivityKind.Warning);

            _currentQueueIndex = 0;
            _currentProcessedRecipeId = 0;
            _currentProcessedRecipeCount = 0;
            _currentProcessedRecipeTotal = 0;
            _currentState = QueueState.WaitingForGather;
            StateChanged?.Invoke(_currentState);

            if (_executionPlan != null)
            {
                _executionPlan.RefreshFromCurrentInventory();
                CraftingGatherBridge.CreateGatherListForMissingIngredients(MaterialTargets);
            }
            else
            {
                Pause($"Missing materials for {itemName}. Fix the inventory and press Resume.");
            }
            return true;
        }

        _missingIngredientFailures.Remove(failure.RecipeId);
        var pauseReason = $"Craft preparation still cannot assign materials for {itemName}: {failure.Details}. Fix or acquire the missing materials, then press Resume.";
        GatherBuddy.Log.Warning($"[CraftingQueueProcessor] {pauseReason}");
        ForkVulcanWorkflowSupport.AddActivity(pauseReason, VulcanActivityKind.Error);
        _currentQueueIndex = 0;
        _currentProcessedRecipeId = 0;
        _currentProcessedRecipeCount = 0;
        _currentProcessedRecipeTotal = 0;
        _currentState = QueueState.WaitingForGather;
        StateChanged?.Invoke(_currentState);
        Pause(pauseReason);
        return true;
'@
    $queueContent = Replace-Required $queueContent $old $new 'recover missing-material preparation failures'
    Set-Content -LiteralPath $queuePath -Value $queueContent -Encoding utf8 -NoNewline
    Write-Host 'Applied fork patch: missing crafting materials re-enter acquisition and pause instead of being skipped.'
}
else {
    Write-Host 'Missing-material craft recovery patch already present.'
}

# --- Crafting Status diagnostics --------------------------------------------------
$statusPath = Join-Path $PSScriptRoot '..\GatherBuddy\Gui\CraftingStatusWindow.cs'
$statusContent = Get-Content -LiteralPath $statusPath -Raw

if ($statusContent -notmatch 'DrawRecentActivity\(\)') {
    $old = @'
    public void SetQueueProcessor(CraftingQueueProcessor? processor)
    {
        _queueProcessor = processor;
        ResetRemainingEstimateCache();
'@
    $new = @'
    public void SetQueueProcessor(CraftingQueueProcessor? processor)
    {
        if (_queueProcessor != null)
            _queueProcessor.StateChanged -= OnQueueStateChanged;
        _queueProcessor = processor;
        if (_queueProcessor != null)
            _queueProcessor.StateChanged += OnQueueStateChanged;
        ResetRemainingEstimateCache();
'@
    $statusContent = Replace-Required $statusContent $old $new 'subscribe Crafting Status to queue state changes'

    $old = @'
        if (currentItem != null)
        {
            var recipeSheet = Dalamud.GameData.GetExcelSheet<Lumina.Excel.Sheets.Recipe>();
            if (recipeSheet != null && recipeSheet.TryGetRow(currentItem.RecipeId, out var recipe))
            {
                var itemName = recipe.ItemResult.Value.Name.ExtractText();
                ImGui.Text($"Current Recipe: {itemName}");
            }
        }

        if (ShouldShowRemainingEstimate(currentState))
'@
    $new = @'
        if (currentItem != null)
        {
            var recipeSheet = Dalamud.GameData.GetExcelSheet<Lumina.Excel.Sheets.Recipe>();
            if (recipeSheet != null && recipeSheet.TryGetRow(currentItem.RecipeId, out var recipe))
            {
                var itemName = recipe.ItemResult.Value.Name.ExtractText();
                ImGui.Text($"Current Recipe: {itemName}");
            }
        }

        DrawManualMaterialBlockers();

        if (ShouldShowRemainingEstimate(currentState))
'@
    $statusContent = Replace-Required $statusContent $old $new 'render manual material blockers'

    $old = @'
            if (!_queueProcessor.Paused)
            {
                if (ImGui.Button("Pause"))
                {
                    _queueProcessor.Pause();
                }
            }
            else
            {
                if (ImGui.Button("Resume"))
                {
                    _queueProcessor.Resume();
                }
            }
            
            ImGui.SameLine();
            if (ImGui.Button("Stop"))
            {
                CraftingGatherBridge.StopQueue();
            }
'@
    $new = @'
            ImGui.BeginDisabled(_queueProcessor.Paused);
            if (ImGui.Button("Pause"))
            {
                _queueProcessor.Pause();
                ForkVulcanWorkflowSupport.AddActivity("Queue paused by user.", VulcanActivityKind.Info);
            }
            ImGui.EndDisabled();

            ImGui.SameLine();
            ImGui.BeginDisabled(!_queueProcessor.Paused);
            if (ImGui.Button("Resume"))
            {
                CraftingGatherBridge.ResumeQueue();
            }
            ImGui.EndDisabled();

            ImGui.SameLine();
            if (ImGui.Button("Stop"))
            {
                ForkVulcanWorkflowSupport.AddActivity("Queue stopped by user.", VulcanActivityKind.Warning);
                CraftingGatherBridge.StopQueue();
            }
'@
    $statusContent = Replace-Required $statusContent $old $new 'show Pause Resume Stop controls together'

    $old = @'
            if (ImGui.Button("Open Vulcan Window"))
            {
                if (GatherBuddy.VulcanWindow != null)
                {
                    GatherBuddy.VulcanWindow.IsOpen = true;
                }
            }
        }
    }

    private void ResetRemainingEstimateCache()
'@
    $new = @'
            if (ImGui.Button("Open Vulcan Window"))
            {
                if (GatherBuddy.VulcanWindow != null)
                {
                    GatherBuddy.VulcanWindow.IsOpen = true;
                }
            }
        }

        DrawRecentActivity();
    }

    private static void OnQueueStateChanged(CraftingQueueProcessor.QueueState state)
    {
        var kind = state switch
        {
            CraftingQueueProcessor.QueueState.NavigatingToRetainerBell => VulcanActivityKind.Retainer,
            CraftingQueueProcessor.QueueState.WithdrawingFromRetainer => VulcanActivityKind.Retainer,
            CraftingQueueProcessor.QueueState.WaitingForGather => VulcanActivityKind.Gather,
            CraftingQueueProcessor.QueueState.Complete => VulcanActivityKind.Success,
            _ => VulcanActivityKind.Info,
        };
        ForkVulcanWorkflowSupport.AddActivity($"State -> {GetStateDisplayName(state)}", kind);
    }

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

    private static void DrawRecentActivity()
    {
        var activity = ForkVulcanWorkflowSupport.RecentActivity;
        if (activity.Count == 0)
            return;

        ImGui.Spacing();
        ImGui.Separator();
        ImGui.Spacing();
        ImGui.Text("Recent activity");
        ImGui.BeginChild(
            "##VulcanRecentActivity",
            new System.Numerics.Vector2(VulcanUiScaling.Scaled(560f), VulcanUiScaling.Scaled(145f)),
            true);

        var start = Math.Max(0, activity.Count - 12);
        for (var i = start; i < activity.Count; i++)
        {
            var entry = activity[i];
            var color = entry.Kind switch
            {
                VulcanActivityKind.Success => new System.Numerics.Vector4(0.45f, 1.00f, 0.55f, 1.0f),
                VulcanActivityKind.Gather => new System.Numerics.Vector4(0.45f, 0.90f, 1.00f, 1.0f),
                VulcanActivityKind.Retainer => new System.Numerics.Vector4(0.72f, 0.62f, 1.00f, 1.0f),
                VulcanActivityKind.Warning => new System.Numerics.Vector4(1.00f, 0.80f, 0.30f, 1.0f),
                VulcanActivityKind.Error => new System.Numerics.Vector4(1.00f, 0.45f, 0.45f, 1.0f),
                _ => new System.Numerics.Vector4(0.78f, 0.80f, 0.84f, 1.0f),
            };

            ImGui.TextColored(color, $"[{entry.Timestamp:HH:mm:ss}]");
            ImGui.SameLine();
            ImGui.PushTextWrapPos();
            ImGui.TextWrapped(entry.Message);
            ImGui.PopTextWrapPos();
        }

        ImGui.EndChild();
    }

    private void ResetRemainingEstimateCache()
'@
    $statusContent = Replace-Required $statusContent $old $new 'add recent activity panel'

    $old = @'
            CraftingQueueProcessor.QueueState.NavigatingToRetainerBell => "Navigating to Retainer Bell",
            CraftingQueueProcessor.QueueState.WaitingForGather => "Gathering Materials",
'@
    $new = @'
            CraftingQueueProcessor.QueueState.NavigatingToRetainerBell => "Navigating to Retainer Bell",
            CraftingQueueProcessor.QueueState.WithdrawingFromRetainer => "Withdrawing from Retainers",
            CraftingQueueProcessor.QueueState.WaitingForGather => "Gathering Materials",
'@
    $statusContent = Replace-Required $statusContent $old $new 'display retainer withdrawal state'

    Set-Content -LiteralPath $statusPath -Value $statusContent -Encoding utf8 -NoNewline
    Write-Host 'Applied fork patch: Crafting Status manual blockers, Resume control, and Recent activity feed.'
}
else {
    Write-Host 'Crafting Status diagnostics patch already present.'
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
