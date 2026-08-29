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

    Set-Content -LiteralPath $autoGatherPath -Value $autoGather -Encoding utf8 -NoNewline
    Write-Host 'Applied Vulcan gather isolation: AutoGather will not go home mid crafting-material stage.'
}
else {
    Write-Host 'Vulcan idle-travel isolation patch already present.'
}
