$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Content.Contains($Old)) {
        throw "Could not apply retainer-bell reliability patch '$Label'. Earlier fork patches or upstream source changed."
    }

    return $Content.Replace($Old, $New)
}

# Retainer restock is fail-closed, so bell discovery must not be a one-frame test.
# The navigator and withdrawal executor also used to discover the exact same bell
# independently. A transient object-table/targetable mismatch could therefore make
# navigation succeed and the very next withdrawal tick abort immediately.
#
# This pass:
#   * lets the withdrawal executor reuse the bell already selected by navigation;
#   * accepts a targetable bell by localized name regardless of ObjectKind (housing
#     furnishings do not always surface through the same object-kind wrapper);
#   * retries bell discovery for a bounded window instead of aborting on one frame;
#   * records the exact abort reason and exposes it in Crafting Status.

$navigatorPath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\RetainerBellNavigator.cs'
$navigator = Get-Content -LiteralPath $navigatorPath -Raw

if ($navigator -notmatch 'TargetBell => _targetBell') {
    $navigator = Replace-Required $navigator @'
    public bool IsNavigating => _state == NavigationState.Navigating;
'@ @'
    public bool IsNavigating => _state == NavigationState.Navigating;
    internal IGameObject? TargetBell => _targetBell;
'@ 'expose selected navigation bell to withdrawal stage'
    Set-Content -LiteralPath $navigatorPath -Value $navigator -Encoding utf8 -NoNewline
}

$retainerPath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\RetainerTaskExecutor.cs'
$retainer = Get-Content -LiteralPath $retainerPath -Raw

if ($retainer -notmatch 'RETAINER BELL RELIABILITY') {
    $retainer = Replace-Required $retainer @'
    private readonly HashSet<uint> _precraftItemIds;
    private bool _withdrawalPlanBuilt;
'@ @'
    private readonly HashSet<uint> _precraftItemIds;
    private readonly IGameObject? _preferredBell;
    private bool _withdrawalPlanBuilt;
'@ 'store bell selected by navigator'

    $retainer = Replace-Required $retainer @'
    public bool IsComplete => _phase == Phase.Complete;
    public bool IsAborted  => _phase == Phase.Aborted;
'@ @'
    public bool IsComplete => _phase == Phase.Complete;
    public bool IsAborted  => _phase == Phase.Aborted;
    public string AbortReason { get; private set; } = string.Empty;
'@ 'expose precise retainer abort reason'

    $retainer = Replace-Required $retainer @'
    public RetainerTaskExecutor(
        Dictionary<uint, int> materials,
        Dictionary<uint, IngredientQualityDemand> qualityTargets,
        HashSet<uint>? precraftItemIds = null)
    {
        _materials = materials;
        _qualityTargets = qualityTargets;
        _precraftItemIds = precraftItemIds ?? [];
    }
'@ @'
    public RetainerTaskExecutor(
        Dictionary<uint, int> materials,
        Dictionary<uint, IngredientQualityDemand> qualityTargets,
        HashSet<uint>? precraftItemIds = null,
        IGameObject? preferredBell = null)
    {
        _materials = materials;
        _qualityTargets = qualityTargets;
        _precraftItemIds = precraftItemIds ?? [];
        _preferredBell = preferredBell;
    }
'@ 'accept preferred bell from navigation stage'

    $retainer = Replace-Required $retainer @'
    private CraftingTasks.TaskResult TickInteractBell()
    {
        if (Dalamud.Conditions[ConditionFlag.OccupiedSummoningBell])
        {
            GatherBuddy.Log.Debug("[RetainerTaskExecutor] Already at bell, waiting for retainer list");
            _phase = Phase.WaitRetainerList;
            return CraftingTasks.TaskResult.Retry;
        }

        var bell = FindNearestBell();
        if (bell == null)
        {
            GatherBuddy.Log.Warning("[RetainerTaskExecutor] No reachable retainer bell found, aborting retainer stage");
            _phase = Phase.Aborted;
            return CraftingTasks.TaskResult.Done;
        }

        TargetSystem.Instance()->OpenObjectInteraction((FFXIVClientStructs.FFXIV.Client.Game.Object.GameObject*)bell.Address);
        _phase = Phase.WaitOccupied;
        _addonRetryCount = 0;
        Delay(600);
        return CraftingTasks.TaskResult.Retry;
    }
'@ @'
    private CraftingTasks.TaskResult TickInteractBell()
    {
        // RETAINER BELL RELIABILITY: bell lookup is bounded/retryable and reuses
        // the object already selected by RetainerBellNavigator when possible.
        if (Dalamud.Conditions[ConditionFlag.OccupiedSummoningBell])
        {
            GatherBuddy.Log.Debug("[RetainerTaskExecutor] Already at bell, waiting for retainer list");
            _phase = Phase.WaitRetainerList;
            _addonRetryCount = 0;
            return CraftingTasks.TaskResult.Retry;
        }

        var bell = GetUsablePreferredBell() ?? FindNearestBell();
        if (bell == null)
        {
            _addonRetryCount++;
            if (_addonRetryCount > MaxAddonRetries)
                return Abort("No reachable summoning bell was detected after repeated checks, even though the retainer step is active.");

            Delay(150);
            return CraftingTasks.TaskResult.Retry;
        }

        _addonRetryCount = 0;
        TargetSystem.Instance()->OpenObjectInteraction((FFXIVClientStructs.FFXIV.Client.Game.Object.GameObject*)bell.Address);
        _phase = Phase.WaitOccupied;
        Delay(600);
        return CraftingTasks.TaskResult.Retry;
    }
'@ 'retry bell discovery and reuse navigation target'

    $retainer = Replace-Required $retainer @'
        _addonRetryCount++;
        if (_addonRetryCount > MaxAddonRetries)
        {
            GatherBuddy.Log.Warning("[RetainerTaskExecutor] Timed out waiting for OccupiedSummoningBell");
            _phase = Phase.Aborted;
            return CraftingTasks.TaskResult.Done;
        }
'@ @'
        _addonRetryCount++;
        if (_addonRetryCount > MaxAddonRetries)
            return Abort("The summoning bell was found and interaction was requested, but the game never entered the summoning-bell interaction state.");
'@ 'preserve interaction timeout reason'

    $retainer = Replace-Required $retainer @'
                    if (_addonRetryCount > MaxAddonRetries)
                    {
                        GatherBuddy.Log.Warning("[RetainerTaskExecutor] Timed out building retainer withdrawal plan after opening RetainerList");
                        _phase = Phase.Aborted;
                        return CraftingTasks.TaskResult.Done;
                    }
'@ @'
                    if (_addonRetryCount > MaxAddonRetries)
                        return Abort("The retainer list opened, but Vulcan could not build a usable withdrawal plan from the current retainer data.");
'@ 'preserve withdrawal-plan timeout reason'

    $retainer = Replace-Required $retainer @'
        _addonRetryCount++;
        if (_addonRetryCount > MaxAddonRetries)
        {
            GatherBuddy.Log.Warning("[RetainerTaskExecutor] Timed out waiting for RetainerList");
            _phase = Phase.Aborted;
            return CraftingTasks.TaskResult.Done;
        }
'@ @'
        _addonRetryCount++;
        if (_addonRetryCount > MaxAddonRetries)
            return Abort("The summoning-bell interaction started, but the retainer list never became available.");
'@ 'preserve retainer-list timeout reason'

    $retainer = Replace-Required $retainer @'
        _addonRetryCount++;
        if (_addonRetryCount > MaxAddonRetries)
        {
            GatherBuddy.Log.Warning("[RetainerTaskExecutor] Timed out waiting for retainer SelectString");
            _phase = Phase.Aborted;
            return CraftingTasks.TaskResult.Done;
        }
'@ @'
        _addonRetryCount++;
        if (_addonRetryCount > MaxAddonRetries)
            return Abort("A retainer was selected, but its interaction menu never became available.");
'@ 'preserve retainer-menu timeout reason'

    $retainer = Replace-Required $retainer @'
        foreach (var obj in Dalamud.Objects)
        {
            if (obj.ObjectKind != ObjectKind.HousingEventObject && obj.ObjectKind != ObjectKind.EventObj)
                continue;

            var name = obj.Name.TextValue;
'@ @'
        foreach (var obj in Dalamud.Objects)
        {
            // Do not require a specific ObjectKind here. Housing bells can be
            // surfaced through different wrappers; name + targetability is the
            // stable signal we actually need.
            var name = obj.Name.TextValue;
'@ 'allow bell candidates regardless of object kind'

    # The same object-kind block exists in FindNearestBell() as well.
    $retainer = Replace-Required $retainer @'
        foreach (var obj in Dalamud.Objects)
        {
            if (obj.ObjectKind != ObjectKind.HousingEventObject && obj.ObjectKind != ObjectKind.EventObj)
                continue;

            var name = obj.Name.TextValue;
'@ @'
        foreach (var obj in Dalamud.Objects)
        {
            var name = obj.Name.TextValue;
'@ 'allow interaction bell candidates regardless of object kind'

    $retainer = Replace-Required $retainer @'
    private void Delay(int ms)
    {
        _nextRetry = DateTime.Now.AddMilliseconds(ms);
    }
'@ @'
    private IGameObject? GetUsablePreferredBell()
    {
        if (_preferredBell == null)
            return null;

        try
        {
            var player = Dalamud.Objects.LocalPlayer;
            if (player == null || !_preferredBell.IsTargetable)
                return null;

            var maxDist = _preferredBell.ObjectKind == ObjectKind.HousingEventObject ? 6.5f : 4.75f;
            return Vector3.Distance(_preferredBell.Position, player.Position) <= maxDist
                ? _preferredBell
                : null;
        }
        catch
        {
            // The object reference can become stale if game state changes; the
            // normal object-table lookup below will reacquire it safely.
            return null;
        }
    }

    private CraftingTasks.TaskResult Abort(string reason)
    {
        AbortReason = reason;
        GatherBuddy.Log.Warning($"[RetainerTaskExecutor] {reason}");
        _phase = Phase.Aborted;
        return CraftingTasks.TaskResult.Done;
    }

    private void Delay(int ms)
    {
        _nextRetry = DateTime.Now.AddMilliseconds(ms);
    }
'@ 'add preferred-bell validation and precise abort helper'

    Set-Content -LiteralPath $retainerPath -Value $retainer -Encoding utf8 -NoNewline
}

$queuePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingQueueProcessor.cs'
$queue = Get-Content -LiteralPath $queuePath -Raw

if ($queue -notmatch 'TargetBell\)') {
    $queue = Replace-Required $queue @'
        _retainerExecutor = new RetainerTaskExecutor(combinedItems, qualityTargets, RetainerPrecraftTargets.Keys.ToHashSet());
'@ @'
        _retainerExecutor = new RetainerTaskExecutor(
            combinedItems,
            qualityTargets,
            RetainerPrecraftTargets.Keys.ToHashSet(),
            _retainerBellNavigator?.TargetBell);
'@ 'reuse navigator bell in retainer executor'
}

if ($queue -match 'Retainer restock did not complete\. The queue will not advance until the retainer step succeeds; press Resume to retry\.') {
    $queue = Replace-Required $queue @'
                var reason = "Retainer restock did not complete. The queue will not advance until the retainer step succeeds; press Resume to retry.";
'@ @'
                var abortDetail = _retainerExecutor.AbortReason;
                var reason = string.IsNullOrWhiteSpace(abortDetail)
                    ? "Retainer restock did not complete. The queue will not advance until the retainer step succeeds; press Resume to retry."
                    : $"Retainer restock paused: {abortDetail} Press Resume to retry.";
'@ 'surface precise retainer abort reason'
}

Set-Content -LiteralPath $queuePath -Value $queue -Encoding utf8 -NoNewline
Write-Host 'Applied retainer-bell reliability patch: shared bell target, bounded reacquire, and precise abort diagnostics.'
