$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not $Content.Contains($Old)) {
        throw "Could not apply zoning crash guard '$Label'. Earlier fork patches changed."
    }
    return $Content.Replace($Old, $New)
}

$path = Join-Path $PSScriptRoot '..\GatherBuddy\AutoGather\AutoGather.cs'
$content = Get-Content -LiteralPath $path -Raw

if ($content -notmatch 'VULCAN PASSIVE STATUS SNAPSHOT') {
    $content = Replace-Required $content @'
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
'@ @'
        // VULCAN PASSIVE STATUS SNAPSHOT: CraftingStatusWindow.Draw() must never
        // advance or refresh AutoGather's scheduler. In particular,
        // GetNextOrDefault() can call DoUpdate() -> UpdateTeleportationCosts() ->
        // native Telepo.UpdateAetheryteList(), which is unsafe while a territory
        // transition is tearing down/rebuilding game state.
        public uint VulcanCurrentGatherItemId
            => _currentGatherTarget?.Item?.ItemId ?? 0u;

        public IReadOnlyList<uint> GetVulcanGatherExecutionOrder()
        {
            if (Dalamud.Conditions[Dalamud.Game.ClientState.Conditions.ConditionFlag.BetweenAreas]
             || Dalamud.Conditions[Dalamud.Game.ClientState.Conditions.ConditionFlag.BetweenAreas51])
                return Array.Empty<uint>();

            // Enumerate only the already-computed in-memory target list. This is a
            // UI snapshot only and deliberately does not call GetNextOrDefault(),
            // DoUpdate(), teleport-cost calculation, or any other scheduler logic.
            return _activeItemList
                .Select(target => target.Item?.ItemId ?? 0u)
                .Where(itemId => itemId != 0)
                .Distinct()
                .ToArray();
        }
'@ 'remove scheduler refresh from UI status access'

    Set-Content -LiteralPath $path -Value $content -Encoding utf8 -NoNewline
}

Write-Host 'Applied zoning crash guard: Crafting Status is passive and never refreshes AutoGather scheduler.'
