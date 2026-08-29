$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Content.Contains($Old)) {
        throw "Could not apply retainer orchestration patch '$Label'. An earlier fork patch or upstream source changed."
    }

    return $Content.Replace($Old, $New)
}

# The queue processor owns the retainer-stage decision. Do not re-run the same
# asynchronous Allagan/retainer preflight in CraftingGatherBridge immediately after
# StartQueue(): the two calls can observe different readiness/cache states and start
# navigation and material acquisition concurrently.
#
# Correct flow:
#   StartQueue decides once -> Navigating/Withdrawing OR WaitingForGather.
#   The bridge merely reacts to that state. If a retainer stage is active, it waits;
#   TransitionFromRetainerWithdrawComplete() starts material acquisition afterwards.

$bridgePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingGatherBridge.cs'
$bridge = Get-Content -LiteralPath $bridgePath -Raw

if ($bridge -match 'Retainer stage ownership: queue processor') {
    Write-Host 'Single-owner retainer orchestration patch already present.'
    exit 0
}

$old = @'
        var hasRetainerWork = executionPlan.RetainerRestock
            && ForkVulcanWorkflowSupport.HasUsefulRetainerWork(
                executionPlan.Materials,
                executionPlan.RetainerConsumedCraftables);
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

$new = @'
        // Retainer stage ownership: queue processor decides exactly once in StartQueue().
        // Never call HasUsefulRetainerWork() again here: Allagan/retainer cache readiness
        // can change between two adjacent calls, which previously allowed bell navigation
        // and material/manual-blocker resolution to run at the same time.
        if (_queueProcessor.CurrentState == CraftingQueueProcessor.QueueState.WaitingForGather)
        {
            ForkVulcanWorkflowSupport.AddActivity(
                executionPlan.RetainerRestock
                    ? "No retainer withdrawal is needed; resolving remaining materials."
                    : "Retainer restock is disabled; resolving materials from inventory and gathering.",
                VulcanActivityKind.Info);
            CreateGatherListForMissingIngredients(executionPlan.Materials);
        }
        else if (_queueProcessor.CurrentState is CraftingQueueProcessor.QueueState.NavigatingToRetainerBell
                                            or CraftingQueueProcessor.QueueState.WithdrawingFromRetainer)
        {
            ForkVulcanWorkflowSupport.AddActivity(
                "Retainer stage started; material acquisition will wait until restock completes.",
                VulcanActivityKind.Retainer);
        }
        else
        {
            GatherBuddy.Log.Warning(
                $"[CraftingGatherBridge] Queue started in unexpected state {_queueProcessor.CurrentState}; not starting material acquisition concurrently");
        }
'@

$bridge = Replace-Required $bridge $old $new 'make queue processor the sole retainer-stage owner'
Set-Content -LiteralPath $bridgePath -Value $bridge -Encoding utf8 -NoNewline
Write-Host 'Applied retainer orchestration patch: bridge no longer performs a second retainer preflight.'
