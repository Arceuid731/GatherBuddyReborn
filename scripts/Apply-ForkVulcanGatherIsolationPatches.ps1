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

# Vulcan's generated crafting list is a bag-targeted acquisition stage. Retainers
# are handled explicitly before gathering (when restock is ON) or deliberately
# ignored (when restock is OFF). AutoGather's global CheckRetainers preference must
# therefore never make a temporary Vulcan target look complete just because the
# same item exists on a retainer.
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
        // VULCAN BAG-ONLY TARGET: the crafting supply state machine owns retainer
        // acquisition separately. A generated crafting gather list must therefore
        // be satisfied by the player's bags, never by stock that still sits on a
        // retainer. This override is scoped only to items in Vulcan's temporary list;
        // normal user AutoGather lists keep the global CheckRetainers behaviour.
        var vulcanList = global::GatherBuddy.Crafting.CraftingGatherBridge.GetTemporaryGatherList();
        if (vulcanList is { Enabled: true }
         && vulcanList.Items.Any(item => item.ItemId == gatherable.ItemId))
            return gatherable.GetInventoryCount();

        if (GatherBuddy.Config.AutoGatherConfig.CheckRetainers && AllaganTools.Enabled)
        {
            return (int)AllaganTools.ItemCountOwned(gatherable.ItemId, true, _inventoryTypesArray);
        }

        return gatherable.GetInventoryCount();
    }
'@ 'use bag counts for temporary Vulcan targets'

    Set-Content -LiteralPath $extensionsPath -Value $extensions -Encoding utf8 -NoNewline
    Write-Host 'Applied Vulcan gather isolation: temporary crafting targets ignore retainer stock.'
}
else {
    Write-Host 'Vulcan bag-only gathering count patch already present.'
}

# AutoGather normally honors the user's GoHomeWhenIdle preference whenever it has
# outstanding-but-currently-unavailable targets. During a Vulcan crafting stage,
# Vulcan owns the workflow and must decide when the stage is complete; AutoGather
# must not independently send the player home between crafting materials.
$autoGatherPath = Join-Path $PSScriptRoot '..\GatherBuddy\AutoGather\AutoGather.cs'
$autoGather = Get-Content -LiteralPath $autoGatherPath -Raw

if ($autoGather -notmatch 'VULCAN OWNS IDLE TRAVEL') {
    $autoGather = Replace-Required $autoGather @'
                if (!waitAtAetheryte && GatherBuddy.Config.AutoGatherConfig.GoHomeWhenIdle)
                    if (GoHome())
                        return;
'@ @'
                // VULCAN OWNS IDLE TRAVEL: while a generated crafting list exists,
                // never apply AutoGather's personal GoHomeWhenIdle preference between
                // materials. Stay in the acquisition stage until Vulcan validates it.
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

# Expose only the tiny bit of AutoGather runtime state needed by Crafting Status.
# This lets the fork display the real current target and the same pending order that
# AutoGather itself is using, without duplicating its scheduling heuristics.
if ($autoGather -notmatch 'VULCAN CURRENT GATHER DIAGNOSTIC') {
    $autoGather = Replace-Required $autoGather @'
        private GatherTarget? _currentGatherTarget;
'@ @'
        private GatherTarget? _currentGatherTarget;

        // VULCAN CURRENT GATHER DIAGNOSTIC: read-only status surface for the
        // crafting window. It does not alter AutoGather scheduling.
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
            // Refresh with the same scheduler that Update() uses, then expose only
            // distinct pending item IDs in its actual execution order.
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
Write-Host 'Applied Vulcan gather isolation/runtime diagnostics.'

# Crafting Status should mirror AutoGather rather than alphabetize the plan. The
# current target is highlighted, pending items follow in AutoGather execution order,
# and completed targets move below the remaining work.
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

        // VULCAN AUTO-GATHER ORDER: show the exact pending order selected by
        // AutoGather and make the item currently being worked on obvious.
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

    $status = Replace-Required $status @'
            var color = target.Complete
                ? new System.Numerics.Vector4(0.45f, 1.0f, 0.55f, 1.0f)
                : new System.Numerics.Vector4(0.82f, 0.88f, 1.0f, 1.0f);
            var suffix = target.Complete
                ? "ready"
                : $"{target.Remaining} remaining";
            ImGui.TextColored(color, $"- {target.ItemName}: {target.CurrentQuantity}/{target.TargetQuantity} ({suffix})");
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
            ImGui.TextColored(color, $"{(isCurrent ? ">" : "-")} {target.ItemName}: {target.CurrentQuantity}/{target.TargetQuantity} ({suffix})");
'@ 'highlight current AutoGather target'

    $status = Replace-Required $status @'
            CraftingQueueProcessor.QueueState.WaitingForGather => "Gathering Materials",
'@ @'
            CraftingQueueProcessor.QueueState.WaitingForGather => CraftingGatherBridge.WaitingForSafeCraftingReturn
                ? "Returning to Safe Crafting Area"
                : "Gathering Materials",
'@ 'show safe-return stage in Crafting Status'

    Set-Content -LiteralPath $statusPath -Value $status -Encoding utf8 -NoNewline
    Write-Host 'Applied Crafting Status AutoGather current-target/order display.'
}
else {
    Write-Host 'Crafting Status AutoGather order patch already present.'
}

# Once every material is physically in the bags, never begin crafting in a hostile
# field zone. If the game does not report a sanctuary, reuse GatherBuddy's existing
# HomeNavigationHelper/Lifestream route and require a confirmed sanctuary before the
# queue is allowed to leave WaitingForGather.
$bridgePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingGatherBridge.cs'
$bridge = Get-Content -LiteralPath $bridgePath -Raw

if ($bridge -notmatch 'VULCAN SAFE CRAFTING RETURN') {
    $bridge = Replace-Required $bridge @'
    private static bool _waitingForCollectablesHomeReturn = false;
    private static bool _collectablesHomeReturnStarted = false;
'@ @'
    private static bool _waitingForCollectablesHomeReturn = false;
    private static bool _collectablesHomeReturnStarted = false;

    // VULCAN SAFE CRAFTING RETURN: materials may have been gathered/farmed in a
    // hostile zone. Craft only after the game confirms a sanctuary.
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

                FailSafeCraftingReturn(
                    $"All materials are ready, but Vulcan could not return to a safe crafting area: {error} Press Resume to retry; crafting will not start here.");
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

        // IPC may take a moment to report busy after accepting a command and the
        // sanctuary flag may lag the final zone transition by a few frames. Give
        // both a short settle window before deciding the return failed.
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
        ForkVulcanWorkflowSupport.AddActivity(
            "Safe crafting area confirmed; continuing to crafting.",
            VulcanActivityKind.Success);
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

    # Stop means stop: if Vulcan itself initiated a home return, cancel that Lifestream
    # request as part of the queue lifecycle rather than leaving it running detached.
    $bridge = [regex]::Replace(
        $bridge,
        '(public\s+static\s+void\s+StopQueue\(\)\s*\{)',
        '$1' + "`n        ResetSafeCraftingReturnState(abortTravel: true);",
        1)

    if ($bridge -notmatch 'ResetSafeCraftingReturnState\(abortTravel: true\)') {
        throw "Could not apply Vulcan gather-isolation patch 'cancel safe return on Stop'."
    }

    Set-Content -LiteralPath $bridgePath -Value $bridge -Encoding utf8 -NoNewline
    Write-Host 'Applied safe crafting-area return before synthesis.'
}
else {
    Write-Host 'Safe crafting-area return patch already present.'
}
