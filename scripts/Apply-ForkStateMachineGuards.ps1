$ErrorActionPreference = 'Stop'

function Replace-RegexRequired {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][scriptblock]$Replacement,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $regex.IsMatch($Content)) {
        throw "Could not apply state-machine guard '$Label'. Earlier fork patches or upstream source changed."
    }
    return $regex.Replace($Content, $Replacement, 1)
}

# This patch is intentionally applied LAST. It does not try to infer why an
# out-of-order callback happened; instead it makes illegal stage transitions
# impossible at the public transition points.
#
# Invariant:
#   NavigatingToRetainerBell / WithdrawingFromRetainer
#       -> ONLY retainer code may advance the queue.
#   WaitingForGather
#       -> material acquisition may run and may pause for manual materials.
#   No gather/manual/craft transition is accepted before the retainer stage has
#   explicitly completed.

$bridgePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingGatherBridge.cs'
$bridge = Get-Content -LiteralPath $bridgePath -Raw

if ($bridge -notmatch 'HARD STATE GUARD: material acquisition') {
    # Do not advertise a gather wait while a retainer stage is still active.
    $bridge = Replace-RegexRequired `
        -Content $bridge `
        -Pattern '(public\s+static\s+void\s+StartQueueCraftAndGather\([^\)]*\)\s*\{.*?_queueProcessor\.QueueCompleted\s*\+=\s*OnQueueCompleted;\s*)_waitingForGatherComplete\s*=\s*true;' `
        -Replacement { param($m) $m.Groups[1].Value + '_waitingForGatherComplete = false; // Retainer/gather stage has not been validated yet.' } `
        -Label 'do not pre-arm gather completion before queue state is known'

    # Every queue-mode material acquisition attempt must be authorized by the
    # queue processor state. This protects against stale framework callbacks,
    # AutoGather callbacks, Resume races, and future orchestration changes.
    $bridge = Replace-RegexRequired `
        -Content $bridge `
        -Pattern '(public\s+static\s+void\s+CreateGatherListForMissingIngredients\(Dictionary<uint,\s*int>\s+missing\)\s*\{\s*)' `
        -Replacement {
            param($m)
            $guard = @'
        // HARD STATE GUARD: material acquisition is legal only after the queue
        // processor has explicitly completed/skipped the retainer stage.
        if (_isQueueMode && _queueProcessor != null
            && _queueProcessor.CurrentState != CraftingQueueProcessor.QueueState.WaitingForGather)
        {
            GatherBuddy.Log.Warning(
                $"[CraftingGatherBridge] Ignoring out-of-order material acquisition while queue state is {_queueProcessor.CurrentState}");
            ForkVulcanWorkflowSupport.AddActivity(
                $"Ignored out-of-order material acquisition while state is {_queueProcessor.CurrentState}.",
                VulcanActivityKind.Warning);
            return;
        }

'@
            return $m.Groups[1].Value + $guard
        } `
        -Label 'guard material acquisition entry point'

    # Even if a stale AutoGather completion callback fires, it must not mutate a
    # retainer-stage queue into Manual/Gather/Craft.
    $bridge = Replace-RegexRequired `
        -Content $bridge `
        -Pattern '(public\s+static\s+void\s+OnGatherComplete\(\)\s*\{\s*if\s*\(_isQueueMode\s*&&\s*_queueProcessor\s*!=\s*null\)\s*\{\s*)' `
        -Replacement {
            param($m)
            $guard = @'
            // HARD STATE GUARD: stale gather completion callbacks are harmless.
            if (_queueProcessor.CurrentState != CraftingQueueProcessor.QueueState.WaitingForGather)
            {
                GatherBuddy.Log.Warning(
                    $"[CraftingGatherBridge] Ignoring out-of-order gather completion while queue state is {_queueProcessor.CurrentState}");
                ForkVulcanWorkflowSupport.AddActivity(
                    $"Ignored stale gather completion while state is {_queueProcessor.CurrentState}.",
                    VulcanActivityKind.Warning);
                return;
            }

'@
            return $m.Groups[1].Value + $guard
        } `
        -Label 'guard gather completion entry point'

    Set-Content -LiteralPath $bridgePath -Value $bridge -Encoding utf8 -NoNewline
    Write-Host 'Applied hard state guards to CraftingGatherBridge.'
}
else {
    Write-Host 'CraftingGatherBridge hard state guards already present.'
}

$queuePath = Join-Path $PSScriptRoot '..\GatherBuddy\Crafting\CraftingQueueProcessor.cs'
$queue = Get-Content -LiteralPath $queuePath -Raw

if ($queue -notmatch 'HARD STATE GUARD: manual-material pause') {
    # Manual blockers are a child stage of WaitingForGather. They may NEVER steal
    # ownership from bell navigation or retainer withdrawal.
    $queue = Replace-RegexRequired `
        -Content $queue `
        -Pattern '(public\s+void\s+PauseForManualMaterials\(string\s+reason\)\s*\{\s*)' `
        -Replacement {
            param($m)
            $guard = @'
        // HARD STATE GUARD: manual-material pause is legal only from the material
        // acquisition stage. Never cancel/replace an in-flight retainer stage.
        if (_currentState != QueueState.WaitingForGather)
        {
            GatherBuddy.Log.Error(
                $"[CraftingQueueProcessor] Refusing out-of-order manual-material pause while state is {_currentState}: {reason}");
            ForkVulcanWorkflowSupport.AddActivity(
                $"Blocked illegal Manual Materials transition while state is {_currentState}.",
                VulcanActivityKind.Error);
            return;
        }

'@
            return $m.Groups[1].Value + $guard
        } `
        -Label 'guard manual-material pause'

    # A retainer executor abort is NOT a successful restock. Keep ownership of the
    # retainer stage and pause fail-closed. Do not call Pause() from inside the task
    # callback because Pause() clears _tasks while ProcessTasks() is iterating it.
    $queue = Replace-RegexRequired `
        -Content $queue `
        -Pattern '(_tasks\.Add\(\(\)\s*=>\s*\{\s*)TransitionFromRetainerWithdrawComplete\(\);\s*return\s+CraftingTasks\.TaskResult\.Done;\s*\}\);' `
        -Replacement {
            param($m)
            $replacement = @'
            if (_retainerExecutor?.IsAborted == true)
            {
                var reason = "Retainer restock did not complete. The queue will not advance until the retainer step succeeds; press Resume to retry.";
                GatherBuddy.Log.Warning($"[CraftingQueueProcessor] {reason}");
                ForkVulcanWorkflowSupport.AddActivity(reason, VulcanActivityKind.Error);

                // Fail closed without mutating the task list from inside its own
                // callback. ProcessTasks() will remove this completed callback
                // normally; Resume() will rebuild a fresh retainer executor.
                _retainerExecutor = null;
                _paused = true;
                _pauseReason = reason;
                YesAlready.Unlock();
                return CraftingTasks.TaskResult.Done;
            }

            TransitionFromRetainerWithdrawComplete();
            return CraftingTasks.TaskResult.Done;
        });
'@
            return $m.Groups[1].Value + $replacement
        } `
        -Label 'do not treat aborted retainer withdrawal as success'

    # The transition itself also validates its parent state, so a stale queued task
    # cannot advance the machine after some unrelated state change.
    $queue = Replace-RegexRequired `
        -Content $queue `
        -Pattern '(private\s+unsafe\s+void\s+TransitionFromRetainerWithdrawComplete\(\)\s*\{\s*)' `
        -Replacement {
            param($m)
            $guard = @'
        // HARD STATE GUARD: this transition is the sole successful exit from the
        // retainer stage and is valid only while that stage still owns the queue.
        if (_currentState != QueueState.WithdrawingFromRetainer)
        {
            GatherBuddy.Log.Error(
                $"[CraftingQueueProcessor] Refusing stale retainer-complete transition while state is {_currentState}");
            ForkVulcanWorkflowSupport.AddActivity(
                $"Blocked stale retainer-complete transition while state is {_currentState}.",
                VulcanActivityKind.Error);
            return;
        }

'@
            return $m.Groups[1].Value + $guard
        } `
        -Label 'guard retainer completion transition'

    Set-Content -LiteralPath $queuePath -Value $queue -Encoding utf8 -NoNewline
    Write-Host 'Applied hard state guards to CraftingQueueProcessor.'
}
else {
    Write-Host 'CraftingQueueProcessor hard state guards already present.'
}
