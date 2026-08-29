$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Content.Contains($Old)) {
        throw "Could not apply retainer live-scan patch '$Label'. Upstream or an earlier fork patch changed."
    }

    return $Content.Replace($Old, $New)
}

# Allagan Tools can know that an item exists in retainer storage through its pooled
# ItemCountOwned IPC while its per-retainer/page cache is incomplete. The upstream
# withdrawal planner only uses the detailed cache, so it can silently build an empty
# plan even though Crafting Status correctly shows items on retainers.
#
# If that mismatch is detected, visit retainers and inspect the *live* retainer
# inventory containers after each retainer is opened. This keeps normal fast mapped
# withdrawals unchanged and only takes the slower path when the cache cannot map a
# required pooled count to a specific retainer.

$retainerPath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\RetainerTaskExecutor.cs'
$retainer = Get-Content -LiteralPath $retainerPath -Raw

if ($retainer -match '_useLiveRetainerScan') {
    Write-Host 'Retainer pooled-count live-scan fallback already present.'
    exit 0
}

$retainer = Replace-Required $retainer @'
    private record struct WithdrawTarget(uint ItemId, int AmountHQ, int AmountNQ)
    {
'@ @'
    private record struct WithdrawTarget(uint ItemId, int AmountHQ, int AmountNQ, bool IsLiveScan = false)
    {
'@ 'tag live-scan withdrawal targets'

$retainer = Replace-Required $retainer @'
    private bool _withdrawalPlanBuilt;

    public bool IsComplete => _phase == Phase.Complete;
'@ @'
    private bool _withdrawalPlanBuilt;
    private bool _useLiveRetainerScan;
    private readonly Dictionary<uint, IngredientQualityDemand> _liveRetainerScanDemands = new();

    public bool IsComplete => _phase == Phase.Complete;
'@ 'add live-scan state'

$retainer = Replace-Required $retainer @'
    private bool BuildWithdrawalPlan()
    {
        _retainersToVisit.Clear();
        var perRetainerPlan = new Dictionary<ulong, Dictionary<uint, (int NeedHQ, int NeedNQ)>>();
'@ @'
    private bool BuildWithdrawalPlan()
    {
        _retainersToVisit.Clear();
        _liveRetainerScanDemands.Clear();
        _useLiveRetainerScan = false;
        var perRetainerPlan = new Dictionary<ulong, Dictionary<uint, (int NeedHQ, int NeedNQ)>>();
'@ 'reset live-scan state when rebuilding plan'

$retainer = Replace-Required $retainer @'
            if (remainingDemand.Total <= 0)
                continue;

            foreach (var retainerId in retainerIds)
            {

                int retainerHQ = 0, retainerNQ = 0;
'@ @'
            if (remainingDemand.Total <= 0)
                continue;

            var detailedRetainerTotal = 0;
            foreach (var retainerId in retainerIds)
            {

                int retainerHQ = 0, retainerNQ = 0;
'@ 'track detailed per-retainer availability'

$retainer = Replace-Required $retainer @'
                var crystalPageHQ = (int)AllaganTools.ItemCountHQ(itemId, retainerId, 12001);
                retainerHQ += crystalPageHQ;
                retainerNQ += (int)AllaganTools.ItemCount(itemId, retainerId, 12001) - crystalPageHQ;
                var updatedDemand = remainingDemand.ConsumeSplit(retainerNQ, retainerHQ, out var toTakeNQ, out var toTakeHQ);
'@ @'
                var crystalPageHQ = (int)AllaganTools.ItemCountHQ(itemId, retainerId, 12001);
                retainerHQ += crystalPageHQ;
                retainerNQ += (int)AllaganTools.ItemCount(itemId, retainerId, 12001) - crystalPageHQ;
                detailedRetainerTotal += retainerHQ + retainerNQ;
                var updatedDemand = remainingDemand.ConsumeSplit(retainerNQ, retainerHQ, out var toTakeNQ, out var toTakeHQ);
'@ 'sum detailed retainer availability'

$retainer = Replace-Required $retainer @'
                remainingDemand = updatedDemand;
                if (remainingDemand.Total <= 0)
                    break;
            }
        }

        _perRetainerPlan = perRetainerPlan;
'@ @'
                remainingDemand = updatedDemand;
                if (remainingDemand.Total <= 0)
                    break;
            }

            if (remainingDemand.Total > 0)
            {
                var pooledRetainerTotal = RetainerItemQuery.GetTotalCount(itemId);
                if (pooledRetainerTotal > detailedRetainerTotal)
                {
                    _useLiveRetainerScan = true;
                    GatherBuddy.Log.Information(
                        $"[RetainerTaskExecutor] Pooled retainer availability is not mapped for item {itemId}: pooled={pooledRetainerTotal}, detailed={detailedRetainerTotal}, stillNeeded={remainingDemand.Total}; enabling live retainer scan");
                }
            }
        }

        _perRetainerPlan = perRetainerPlan;
        if (_useLiveRetainerScan)
        {
            InitializeLiveRetainerScanDemands();

            var liveRetainerMgr = RetainerManager.Instance();
            if (liveRetainerMgr == null)
            {
                GatherBuddy.Log.Debug("[RetainerTaskExecutor] RetainerManager unavailable while preparing live retainer scan");
                return false;
            }

            for (uint i = 0; i < liveRetainerMgr->GetRetainerCount(); i++)
            {
                var retainer = liveRetainerMgr->GetRetainerBySortedIndex(i);
                if (retainer == null || retainer->RetainerId == 0)
                    continue;
                _retainersToVisit.Add(new RetainerEntry(i, retainer->RetainerId));
            }

            GatherBuddy.Log.Information(
                $"[RetainerTaskExecutor] Detailed Allagan mapping is incomplete; live-scanning {_retainersToVisit.Count} retainer(s) for {_liveRetainerScanDemands.Count} outstanding item type(s)");
            ForkVulcanWorkflowSupport.AddActivity(
                "Retainer cache could not map every stored material to a specific servant; scanning servant inventories live.",
                VulcanActivityKind.Retainer);
            return _retainersToVisit.Count > 0;
        }
'@ 'fallback to live retainer scan for pooled-only counts'

$retainer = Replace-Required $retainer @'
    private CraftingTasks.TaskResult TickSelectRetainer()
    {
        if (_retainerVisitIndex >= _retainersToVisit.Count)
'@ @'
    private CraftingTasks.TaskResult TickSelectRetainer()
    {
        if (_useLiveRetainerScan && _liveRetainerScanDemands.Values.All(demand => demand.Total <= 0))
        {
            GatherBuddy.Log.Information("[RetainerTaskExecutor] Live retainer scan satisfied all outstanding retainer demands; closing retainer list early");
            _phase = Phase.CloseRetainerList;
            return CraftingTasks.TaskResult.Retry;
        }

        if (_retainerVisitIndex >= _retainersToVisit.Count)
'@ 'stop live scan once all demands are satisfied'

$retainer = Replace-Required $retainer @'
            var entry = _retainersToVisit[_retainerVisitIndex];
            _currentRetainerItems = BuildItemListForRetainer(entry.RetainerId);
            _currentItemIndex = 0;
'@ @'
            var entry = _retainersToVisit[_retainerVisitIndex];
            _currentRetainerItems = _useLiveRetainerScan
                ? BuildLiveItemListForCurrentRetainer(entry.RetainerId)
                : BuildItemListForRetainer(entry.RetainerId);
            _currentItemIndex = 0;
'@ 'build targets from live inventory during fallback'

$retainer = Replace-Required $retainer @'
        if (_lookingForHQ) target.RemainingHQ -= _foundSlotQty;
        else               target.RemainingNQ -= _foundSlotQty;
        _currentRetainerItems[_currentItemIndex] = target;
'@ @'
        if (_lookingForHQ) target.RemainingHQ -= _foundSlotQty;
        else               target.RemainingNQ -= _foundSlotQty;
        if (target.IsLiveScan)
            ConsumeLiveRetainerScanDemand(target.ItemId, _lookingForHQ, _foundSlotQty);
        _currentRetainerItems[_currentItemIndex] = target;
'@ 'account full-stack live-scan withdrawal'

$retainer = Replace-Required $retainer @'
        if (_lookingForHQ) target.RemainingHQ -= value;
        else               target.RemainingNQ -= value;
        _currentRetainerItems[_currentItemIndex] = target;
'@ @'
        if (_lookingForHQ) target.RemainingHQ -= value;
        else               target.RemainingNQ -= value;
        if (target.IsLiveScan)
            ConsumeLiveRetainerScanDemand(target.ItemId, _lookingForHQ, value);
        _currentRetainerItems[_currentItemIndex] = target;
'@ 'account quantity live-scan withdrawal'

$retainer = Replace-Required $retainer @'
    private List<WithdrawTarget> BuildItemListForRetainer(ulong retainerId)
    {
'@ @'
    private void InitializeLiveRetainerScanDemands()
    {
        _liveRetainerScanDemands.Clear();
        foreach (var (itemId, totalNeeded) in _materials)
        {
            var demand = _qualityTargets.TryGetValue(itemId, out var qualityDemand)
                ? qualityDemand
                : IngredientQualityDemand.FromPreferHQ(totalNeeded);

            if (!_precraftItemIds.Contains(itemId))
            {
                int inBagHQ = 0, inBagNQ = 0;
                var inventoryMgr = InventoryManager.Instance();
                if (inventoryMgr != null)
                {
                    inBagHQ = (int)inventoryMgr->GetInventoryItemCount(itemId, true, false, false);
                    inBagNQ = (int)inventoryMgr->GetInventoryItemCount(itemId, false, false, false);
                }
                demand = demand.ConsumeSplit(inBagNQ, inBagHQ, out _, out _);
            }

            if (demand.Total > 0)
                _liveRetainerScanDemands[itemId] = demand;
        }
    }

    private List<WithdrawTarget> BuildLiveItemListForCurrentRetainer(ulong retainerId)
    {
        var list = new List<WithdrawTarget>();
        foreach (var (itemId, demand) in _liveRetainerScanDemands.ToArray())
        {
            if (demand.Total <= 0)
                continue;

            var (availableNQ, availableHQ) = GetCurrentRetainerSplitCounts(itemId);
            if (availableNQ <= 0 && availableHQ <= 0)
                continue;

            _ = demand.ConsumeSplit(availableNQ, availableHQ, out var toTakeNQ, out var toTakeHQ);
            if (toTakeHQ <= 0 && toTakeNQ <= 0)
                continue;

            list.Add(new WithdrawTarget(itemId, toTakeHQ, toTakeNQ, true));
            GatherBuddy.Log.Debug(
                $"[RetainerTaskExecutor] Live scan retainer {retainerId}: item {itemId} available HQ={availableHQ} NQ={availableNQ}, taking HQ={toTakeHQ} NQ={toTakeNQ}");
        }

        GatherBuddy.Log.Debug($"[RetainerTaskExecutor] Built live-scan item list for retainer {retainerId}: {list.Count} item(s)");
        return list;
    }

    private static (int NQ, int HQ) GetCurrentRetainerSplitCounts(uint itemId)
    {
        var inventoryManager = InventoryManager.Instance();
        if (inventoryManager == null)
            return (0, 0);

        var totalNQ = 0;
        var totalHQ = 0;
        var inventories = new[]
        {
            InventoryType.RetainerPage1, InventoryType.RetainerPage2, InventoryType.RetainerPage3,
            InventoryType.RetainerPage4, InventoryType.RetainerPage5, InventoryType.RetainerPage6,
            InventoryType.RetainerPage7, InventoryType.RetainerCrystals
        };

        foreach (var inv in inventories)
        {
            var container = inventoryManager->GetInventoryContainer(inv);
            if (container == null)
                continue;

            for (var i = 0; i < container->Size; i++)
            {
                var slot = container->GetInventorySlot(i);
                if (slot == null || slot->ItemId != itemId)
                    continue;

                if (slot->Flags.HasFlag(InventoryItem.ItemFlags.HighQuality))
                    totalHQ += (int)slot->Quantity;
                else
                    totalNQ += (int)slot->Quantity;
            }
        }

        return (totalNQ, totalHQ);
    }

    private void ConsumeLiveRetainerScanDemand(uint itemId, bool isHQ, int quantity)
    {
        if (quantity <= 0 || !_liveRetainerScanDemands.TryGetValue(itemId, out var demand))
            return;

        var remaining = isHQ
            ? demand.ConsumeSplit(0, quantity, out _, out _)
            : demand.ConsumeSplit(quantity, 0, out _, out _);
        _liveRetainerScanDemands[itemId] = remaining;
        GatherBuddy.Log.Debug(
            $"[RetainerTaskExecutor] Live-scan demand updated for item {itemId}: {remaining.Total} remaining");
    }

    private List<WithdrawTarget> BuildItemListForRetainer(ulong retainerId)
    {
'@ 'add live inventory scan helpers'

Set-Content -LiteralPath $retainerPath -Value $retainer -Encoding utf8 -NoNewline
Write-Host 'Applied retainer patch: pooled Allagan counts fall back to live servant inventory scanning.'
