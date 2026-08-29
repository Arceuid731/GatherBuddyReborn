$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not $Content.Contains($Old)) {
        throw "Could not apply Vulcan gather-isolation patch '$Label'. Upstream or an earlier fork patch changed."
    }
    return $Content.Replace($Old, $New)
}

# --- Bag-only temporary Vulcan targets -------------------------------------------
$extensionsPath = Join-Path $PSScriptRoot '..\GatherBuddy\AutoGather\Extensions\GatherableExtensions.cs'
$extensions = Get-Content -LiteralPath $extensionsPath -Raw
if ($extensions -notmatch 'VULCAN BAG-ONLY TARGET') {
    $extensions = Replace-Required $extensions @'
    public static int GetTotalCount(this IGatherable gatherable)
    {
        if (GatherBuddy.Config.AutoGatherConfig.CheckRetainers && AllaganTools.Enabled)
        {
            return (int)AllaganTools.ItemCountOwned(gatherable.ItemId, true, _inventoryTypesArray);
        }

        return gatherable.GetInventoryCount();
    }
'@ @'
    public static int GetTotalCount(this IGatherable gatherable)
    {
        // VULCAN BAG-ONLY TARGET: retainer acquisition is a separate Vulcan stage.
        var vulcanList = global::GatherBuddy.Crafting.CraftingGatherBridge.GetTemporaryGatherList();
        if (vulcanList is { Enabled: true }
         && vulcanList.Items.Any(item => item.ItemId == gatherable.ItemId))
            return gatherable.GetInventoryCount();

        if (GatherBuddy.Config.AutoGatherConfig.CheckRetainers && AllaganTools.Enabled)
            return (int)AllaganTools.ItemCountOwned(gatherable.ItemId, true, _inventoryTypesArray);

        return gatherable.GetInventoryCount();
    }
'@ 'use bag counts for temporary Vulcan targets'
    Set-Content -LiteralPath $extensionsPath -Value $extensions -Encoding utf8 -NoNewline
}

# --- AutoGather ownership + read-only runtime diagnostics -------------------------
$autoGatherPath = Join-Path $PSScriptRoot '..\GatherBuddy\AutoGather\AutoGather.cs'
$autoGather = Get-Content -LiteralPath $autoGatherPath -Raw
if ($autoGather -notmatch 'VULCAN OWNS IDLE TRAVEL') {
    $autoGather = Replace-Required $autoGather @'
                if (!waitAtAetheryte && GatherBuddy.Config.AutoGatherConfig.GoHomeWhenIdle)
                    if (GoHome())
                        return;
'@ @'
                // VULCAN OWNS IDLE TRAVEL: Vulcan validates completion itself.
                var vulcanCraftingGatherActive = global::GatherBuddy.Crafting.CraftingGatherBridge.GetTemporaryGatherList()
                    is { Enabled: true };
                if (!waitAtAetheryte
                 && !vulcanCraftingGatherActive
                 && GatherBuddy.Config.AutoGatherConfig.GoHomeWhenIdle)
                {
                    if (GoHome())
                        return;
                }
'@ 'prevent GoHomeWhenIdle from interrupting Vulcan gathering'
}

if ($autoGather -notmatch 'VULCAN CURRENT GATHER DIAGNOSTIC') {
    $autoGather = Replace-Required $autoGather @'
        private GatherTarget? _currentGatherTarget;
'@ @'
        private GatherTarget? _currentGatherTarget;

        // VULCAN CURRENT GATHER DIAGNOSTIC: read-only status data for Crafting Status.
        public uint VulcanCurrentGatherItemId
        {
            get
            {
                var target = _currentGatherTarget ?? _activeItemList.CurrentOrDefault;
                return target.Item?.ItemId ?? 0u;
            }
        }

        public IReadOnlyList<uint> GetVulcanGatherExecutionOrder()
        {
            _activeItemList.GetNextOrDefault();
            return _activeItemList
                .Select(target => target.Item?.ItemId ?? 0u)
                .Where(itemId => itemId != 0)
                .Distinct()
                .ToArray();
        }
'@ 'expose current AutoGather target and execution order'
}
Set-Content -LiteralPath $autoGatherPath -Value $autoGather -Encoding utf8 -NoNewline
Write-Host 'Applied Vulcan bag-only/idle-travel isolation and AutoGather diagnostics.'

# --- Crafting Status follows real AutoGather order -------------------------------
$statusPath = Join-Path $PSScriptRoot '..\GatherBuddy\Gui\CraftingStatusWindow.cs'
$status = Get-Content -LiteralPath $statusPath -Raw
if ($status -notmatch 'VULCAN AUTO-GATHER ORDER') {
    $status = Replace-Required $status @'
        var targets = ForkVulcanWorkflowSupport.GetGatherTargetStatus();
        if (targets.Count == 0)
            return;
'@ @'
        var targets = ForkVulcanWorkflowSupport.GetGatherTargetStatus().ToList();
        if (targets.Count == 0)
            return;

        // VULCAN AUTO-GATHER ORDER: pending work mirrors AutoGather's scheduler.
        var currentGatherItemId = GatherBuddy.AutoGather.VulcanCurrentGatherItemId;
        var executionOrder = GatherBuddy.AutoGather.GetVulcanGatherExecutionOrder();
        var executionIndex = executionOrder
            .Select((itemId, index) => (itemId, index))
            .ToDictionary(entry => entry.itemId, entry => entry.index);
        targets = targets
            .OrderBy(target => target.Complete ? 1 : 0)
            .ThenBy(target => target.ItemId == currentGatherItemId ? -1 : executionIndex.GetValueOrDefault(target.ItemId, int.MaxValue))
            .ThenBy(target => target.ItemName, StringComparer.OrdinalIgnoreCase)
            .ToList();
'@ 'order Crafting Status targets like AutoGather'

    # Supply-plan patches already added the retainer hint between suffix and render.
    $status = Replace-Required $status @'
            var color = target.Complete
                ? new System.Numerics.Vector4(0.45f, 1.0f, 0.55f, 1.0f)
                : new System.Numerics.Vector4(0.82f, 0.88f, 1.0f, 1.0f);
            var suffix = target.Complete
                ? "ready"
                : $"{target.Remaining} remaining";
            var retainerSuffix = target.RetainerAvailable > 0
                ? $" — Retainers: {target.RetainerAvailable} available (restock OFF)"
                : string.Empty;
            ImGui.TextColored(color, $"- {target.ItemName}: {target.CurrentQuantity}/{target.TargetQuantity} ({suffix}){retainerSuffix}");
            // Vendor alternative: intentionally not rendered when GatherFirst is selected.
'@ @'
            var isCurrent = !target.Complete && target.ItemId == currentGatherItemId;
            var color = target.Complete
                ? new System.Numerics.Vector4(0.45f, 1.0f, 0.55f, 1.0f)
                : isCurrent
                    ? new System.Numerics.Vector4(1.0f, 0.86f, 0.35f, 1.0f)
                    : new System.Numerics.Vector4(0.82f, 0.88f, 1.0f, 1.0f);
            var suffix = target.Complete
                ? "ready"
                : isCurrent
                    ? $"{target.Remaining} remaining — gathering now"
                    : $"{target.Remaining} remaining";
            var retainerSuffix = target.RetainerAvailable > 0
                ? $" — Retainers: {target.RetainerAvailable} available (restock OFF)"
                : string.Empty;
            ImGui.TextColored(color, $"{(isCurrent ? ">" : "-")} {target.ItemName}: {target.CurrentQuantity}/{target.TargetQuantity} ({suffix}){retainerSuffix}");
            // Vendor alternative: intentionally not rendered when GatherFirst is selected.
'@ 'highlight current AutoGather target'

    $status = Replace-Required $status @'
            CraftingQueueProcessor.QueueState.WaitingForGather => "Gathering Materials",
'@ @'
            CraftingQueueProcessor.QueueState.WaitingForGather => CraftingGatherBridge.WaitingForSafeCraftingReturn
                ? "Returning to Safe Crafting Area"
                : "Gathering Materials",
'@ 'show safe-return stage in Crafting Status'

    Set-Content -LiteralPath $statusPath -Value $status -Encoding utf8 -NoNewline
}
Write-Host 'Applied ordered/current AutoGather display in Crafting Status.'

# --- Require a confirmed sanctuary before crafting -------------------------------
$bridgePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingGatherBridge.cs'
$bridge = Get-Content -LiteralPath $bridgePath -Raw
if ($bridge -notmatch 'VULCAN SAFE CRAFTING RETURN') {
    $bridge = Replace-Required $bridge @'
    private static bool _waitingForCollectablesHomeReturn = false;
    private static bool _collectablesHomeReturnStarted = false;
'@ @'
    private static bool _waitingForCollectablesHomeReturn = false;
    private static bool _collectablesHomeReturnStarted = false;

    // VULCAN SAFE CRAFTING RETURN: never synthesize in an unconfirmed field area.
    private static bool _waitingForSafeCraftingReturn = false;
    private static bool _safeCraftingReturnStarted = false;
    private static bool _safeCraftingReturnObservedBusy = false;
    private static DateTime _safeCraftingReturnStartedAt = DateTime.MinValue;
    private static DateTime _safeCraftingReturnIdleSince = DateTime.MinValue;
    public static bool WaitingForSafeCraftingReturn => _waitingForSafeCraftingReturn;
'@ 'add safe crafting return state'

    $bridge = Replace-Required $bridge @'
            UpdateCollectablesHomeReturnBeforeResume();
            TryStartCollectablesInterruption();
            _queueProcessor.Update();
'@ @'
            UpdateCollectablesHomeReturnBeforeResume();
            UpdateSafeCraftingReturnBeforeCraft();
            TryStartCollectablesInterruption();
            _queueProcessor.Update();
'@ 'update safe crafting return before queue processing'

    $bridge = Replace-Required $bridge @'
        ResetCollectablesInterruptionState();
        _lastCollectablesHardFailLog = DateTime.MinValue;
'@ @'
        ResetCollectablesInterruptionState();
        ResetSafeCraftingReturnState();
        _lastCollectablesHardFailLog = DateTime.MinValue;
'@ 'reset safe return at queue start'

    $bridge = Replace-Required $bridge @'
    public static void OnCraftFinished(Recipe? recipe, bool cancelled)
'@ @'
    private static void StartSafeCraftingReturn()
    {
        if (_waitingForSafeCraftingReturn)
            return;

        _waitingForSafeCraftingReturn = true;
        _safeCraftingReturnStarted = false;
        _safeCraftingReturnObservedBusy = false;
        _safeCraftingReturnStartedAt = DateTime.MinValue;
        _safeCraftingReturnIdleSince = DateTime.MinValue;
        ForkVulcanWorkflowSupport.AddActivity(
            "All materials are ready; returning to a safe crafting area before starting synthesis.",
            VulcanActivityKind.Info);
    }

    private static void UpdateSafeCraftingReturnBeforeCraft()
    {
        if (!_waitingForSafeCraftingReturn || _queueProcessor == null)
            return;

        if (HomeNavigationHelper.IsInSafeCraftingArea()
         && (!Lifestream.Enabled || !Lifestream.IsBusy()))
        {
            CompleteSafeCraftingReturn();
            return;
        }

        if (!_safeCraftingReturnStarted)
        {
            if (Lifestream.Enabled && Lifestream.IsBusy())
                return;

            if (!HomeNavigationHelper.TryStartReturnHome(out var error))
            {
                if (string.IsNullOrWhiteSpace(error))
                    return;
                FailSafeCraftingReturn($"All materials are ready, but Vulcan could not return to a safe crafting area: {error} Press Resume to retry; crafting will not start here.");
                return;
            }

            _safeCraftingReturnStarted = true;
            _safeCraftingReturnStartedAt = DateTime.UtcNow;
            _safeCraftingReturnIdleSince = DateTime.MinValue;
            ForkVulcanWorkflowSupport.AddActivity(
                "Lifestream home return started; waiting for a confirmed sanctuary before crafting.",
                VulcanActivityKind.Info);
            return;
        }

        if (Lifestream.Enabled && Lifestream.IsBusy())
        {
            _safeCraftingReturnObservedBusy = true;
            _safeCraftingReturnIdleSince = DateTime.MinValue;
            return;
        }

        if (_safeCraftingReturnIdleSince == DateTime.MinValue)
        {
            _safeCraftingReturnIdleSince = DateTime.UtcNow;
            return;
        }

        if ((DateTime.UtcNow - _safeCraftingReturnIdleSince) < TimeSpan.FromSeconds(1))
            return;

        if (HomeNavigationHelper.IsInSafeCraftingArea())
        {
            CompleteSafeCraftingReturn();
            return;
        }

        if (_safeCraftingReturnObservedBusy
         || (DateTime.UtcNow - _safeCraftingReturnStartedAt) >= TimeSpan.FromSeconds(10))
        {
            FailSafeCraftingReturn(
                "Lifestream finished the home-return attempt, but the game still does not report a sanctuary. Vulcan paused instead of crafting in an unsafe area. Press Resume to retry.");
        }
    }

    private static void CompleteSafeCraftingReturn()
    {
        ResetSafeCraftingReturnState();
        ForkVulcanWorkflowSupport.AddActivity("Safe crafting area confirmed; continuing to crafting.", VulcanActivityKind.Success);
        _queueProcessor?.OnGatherComplete();
    }

    private static void FailSafeCraftingReturn(string reason)
    {
        ResetSafeCraftingReturnState();
        GatherBuddy.Log.Warning($"[CraftingGatherBridge] {reason}");
        ForkVulcanWorkflowSupport.AddActivity(reason, VulcanActivityKind.Error);
        _queueProcessor?.Pause(reason);
    }

    private static void ResetSafeCraftingReturnState(bool abortTravel = false)
    {
        if (abortTravel && _waitingForSafeCraftingReturn && Lifestream.Enabled && Lifestream.IsBusy())
            Lifestream.Abort();
        _waitingForSafeCraftingReturn = false;
        _safeCraftingReturnStarted = false;
        _safeCraftingReturnObservedBusy = false;
        _safeCraftingReturnStartedAt = DateTime.MinValue;
        _safeCraftingReturnIdleSince = DateTime.MinValue;
    }

    public static void OnCraftFinished(Recipe? recipe, bool cancelled)
'@ 'add safe crafting return lifecycle'

    $bridge = Replace-Required $bridge @'
            ForkVulcanWorkflowSupport.ClearGatherTargets();
            ForkVulcanWorkflowSupport.ClearManualBlockers();
            ForkVulcanWorkflowSupport.AddActivity("All required materials are in the inventory; continuing to crafting.", VulcanActivityKind.Success);
            _queueProcessor.OnGatherComplete();
            return;
'@ @'
            ForkVulcanWorkflowSupport.ClearGatherTargets();
            ForkVulcanWorkflowSupport.ClearManualBlockers();

            if (!HomeNavigationHelper.IsInSafeCraftingArea())
            {
                StartSafeCraftingReturn();
                return;
            }

            ForkVulcanWorkflowSupport.AddActivity("All required materials are in the inventory and the current area is safe; continuing to crafting.", VulcanActivityKind.Success);
            _queueProcessor.OnGatherComplete();
            return;
'@ 'require sanctuary before crafting'

    $bridge = [regex]::Replace(
        $bridge,
        '(public\s+static\s+void\s+StopQueue\(\)\s*\{)',
        '$1' + "`n        ResetSafeCraftingReturnState(abortTravel: true);",
        1)
    if ($bridge -notmatch 'ResetSafeCraftingReturnState\(abortTravel: true\)') {
        throw "Could not apply Vulcan gather-isolation patch 'cancel safe return on Stop'."
    }

    Set-Content -LiteralPath $bridgePath -Value $bridge -Encoding utf8 -NoNewline
}
Write-Host 'Applied sanctuary-gated safe return before crafting.'
