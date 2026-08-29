$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Content.Contains($Old)) {
        throw "Could not apply retainer bell interaction patch '$Label'. Upstream or an earlier fork patch changed."
    }

    return $Content.Replace($Old, $New)
}

# The upstream retainer flow interacts with the bell exactly once, immediately after
# vnavmesh reports arrival. If that interaction is ignored by the game (for example
# while the client is still settling after movement), WaitOccupied only waits for
# OccupiedSummoningBell and never retries the interaction. AutoGather already avoids
# the same class of race by delaying interaction after stopping movement.
#
# Give movement a short settling window, then retry the bell interaction at a bounded
# cadence until the retainer list/talk/occupied state proves that it succeeded.

$retainerPath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\RetainerTaskExecutor.cs'
$retainer = Get-Content -LiteralPath $retainerPath -Raw

if ($retainer -match 'Retrying summoning bell interaction') {
    Write-Host 'Retainer bell interaction retry patch already present.'
    exit 0
}

$retainer = Replace-Required $retainer @'
    private int _addonRetryCount = 0;
    private const int MaxAddonRetries = 40;
'@ @'
    private int _addonRetryCount = 0;
    private DateTime _bellInteractionReadyAt = DateTime.MinValue;
    private DateTime _lastBellInteractionAttempt = DateTime.MinValue;
    private const int MaxAddonRetries = 40;
    private const int BellInteractionSettleMilliseconds = 250;
    private const int BellInteractionRetryMilliseconds = 900;
'@ 'add bell interaction timing state'

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
        if (Dalamud.Conditions[ConditionFlag.OccupiedSummoningBell])
        {
            GatherBuddy.Log.Debug("[RetainerTaskExecutor] Already at bell, waiting for retainer list");
            _phase = Phase.WaitRetainerList;
            return CraftingTasks.TaskResult.Retry;
        }

        if (GenericHelpers.TryGetAddonByName<AtkUnitBase>("RetainerList", out var existingList) && existingList->IsVisible)
        {
            GatherBuddy.Log.Debug("[RetainerTaskExecutor] Retainer list is already visible");
            _phase = Phase.WaitRetainerList;
            return CraftingTasks.TaskResult.Retry;
        }

        // vnavmesh may have stopped this frame while the game still considers the
        // character to be settling from movement. Do not spend our only interaction
        // attempt in that race window.
        if (_bellInteractionReadyAt == DateTime.MinValue)
        {
            _bellInteractionReadyAt = DateTime.Now.AddMilliseconds(BellInteractionSettleMilliseconds);
            GatherBuddy.Log.Debug($"[RetainerTaskExecutor] Bell reached; waiting {BellInteractionSettleMilliseconds}ms before interaction");
            Delay(BellInteractionSettleMilliseconds);
            return CraftingTasks.TaskResult.Retry;
        }

        var bell = FindNearestBell();
        if (bell == null)
        {
            GatherBuddy.Log.Warning("[RetainerTaskExecutor] No reachable retainer bell found, aborting retainer stage");
            _phase = Phase.Aborted;
            return CraftingTasks.TaskResult.Done;
        }

        var targetSystem = TargetSystem.Instance();
        if (targetSystem == null)
        {
            GatherBuddy.Log.Warning("[RetainerTaskExecutor] TargetSystem unavailable while interacting with summoning bell");
            _phase = Phase.Aborted;
            return CraftingTasks.TaskResult.Done;
        }

        GatherBuddy.Log.Debug("[RetainerTaskExecutor] Interacting with summoning bell");
        targetSystem->OpenObjectInteraction((FFXIVClientStructs.FFXIV.Client.Game.Object.GameObject*)bell.Address);
        _lastBellInteractionAttempt = DateTime.Now;
        _phase = Phase.WaitOccupied;
        _addonRetryCount = 0;
        Delay(300);
        return CraftingTasks.TaskResult.Retry;
    }
'@ 'delay initial bell interaction after navigation'

$retainer = Replace-Required $retainer @'
    private CraftingTasks.TaskResult TickWaitOccupied()
    {
        if (Dalamud.Conditions[ConditionFlag.OccupiedSummoningBell])
        {
            _phase = Phase.WaitRetainerList;
            _addonRetryCount = 0;
            return CraftingTasks.TaskResult.Retry;
        }

        if (GenericHelpers.TryGetAddonByName<AddonTalk>("Talk", out var talk) && talk->AtkUnitBase.IsVisible)
        {
            GatherBuddy.Log.Debug("[RetainerTaskExecutor] Talk dialog visible, dismissing");
            new AddonMaster.Talk((nint)talk).Click();
            Delay(300);
            return CraftingTasks.TaskResult.Retry;
        }

        _addonRetryCount++;
        if (_addonRetryCount > MaxAddonRetries)
        {
            GatherBuddy.Log.Warning("[RetainerTaskExecutor] Timed out waiting for OccupiedSummoningBell");
            _phase = Phase.Aborted;
            return CraftingTasks.TaskResult.Done;
        }

        Delay(150);
        return CraftingTasks.TaskResult.Retry;
    }
'@ @'
    private CraftingTasks.TaskResult TickWaitOccupied()
    {
        if (Dalamud.Conditions[ConditionFlag.OccupiedSummoningBell])
        {
            _phase = Phase.WaitRetainerList;
            _addonRetryCount = 0;
            return CraftingTasks.TaskResult.Retry;
        }

        // Some clients expose the list before the condition flag is observed by the
        // plugin. Treat the UI itself as success as well.
        if (GenericHelpers.TryGetAddonByName<AtkUnitBase>("RetainerList", out var retainerList) && retainerList->IsVisible)
        {
            GatherBuddy.Log.Debug("[RetainerTaskExecutor] Retainer list visible after bell interaction");
            _phase = Phase.WaitRetainerList;
            _addonRetryCount = 0;
            return CraftingTasks.TaskResult.Retry;
        }

        if (GenericHelpers.TryGetAddonByName<AddonTalk>("Talk", out var talk) && talk->AtkUnitBase.IsVisible)
        {
            GatherBuddy.Log.Debug("[RetainerTaskExecutor] Talk dialog visible, dismissing");
            new AddonMaster.Talk((nint)talk).Click();
            Delay(300);
            return CraftingTasks.TaskResult.Retry;
        }

        _addonRetryCount++;
        if (_addonRetryCount > MaxAddonRetries)
        {
            GatherBuddy.Log.Warning("[RetainerTaskExecutor] Timed out waiting for OccupiedSummoningBell after repeated interaction attempts");
            _phase = Phase.Aborted;
            return CraftingTasks.TaskResult.Done;
        }

        if (_lastBellInteractionAttempt == DateTime.MinValue ||
            (DateTime.Now - _lastBellInteractionAttempt).TotalMilliseconds >= BellInteractionRetryMilliseconds)
        {
            var bell = FindNearestBell();
            var targetSystem = TargetSystem.Instance();
            if (bell != null && targetSystem != null)
            {
                GatherBuddy.Log.Debug("[RetainerTaskExecutor] Retrying summoning bell interaction");
                targetSystem->OpenObjectInteraction((FFXIVClientStructs.FFXIV.Client.Game.Object.GameObject*)bell.Address);
                _lastBellInteractionAttempt = DateTime.Now;
                Delay(300);
                return CraftingTasks.TaskResult.Retry;
            }
        }

        Delay(150);
        return CraftingTasks.TaskResult.Retry;
    }
'@ 'retry failed bell interactions while waiting for occupied state'

Set-Content -LiteralPath $retainerPath -Value $retainer -Encoding utf8 -NoNewline
Write-Host 'Applied retainer patch: settle after navigation and retry summoning bell interaction until confirmed.'
