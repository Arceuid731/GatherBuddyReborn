using GatherBuddy.Crafting;

var passed = 0;
void Check(bool condition, string name) { if (!condition) throw new Exception(name); passed++; Console.WriteLine($"PASS {name}"); }
var queue = new QueueHarness();
queue.PauseFailedRaphaelItem(new(1047, false));
Check(queue._paused && queue._craftBlocked && queue._currentQueueIndex == 1, "Failed intermediate pauses without advancing");
Check(queue._raphaelCoordinator.Removed == 0, "Failure does not retry automatically");
queue.Resume();
Check(!queue._paused && !queue._craftBlocked && queue._currentQueueIndex == 0, "Explicit Resume returns to acquisition");
Check(queue._raphaelCoordinator.Removed == 1 && queue._enqueuedRaphaelRequests.Count == 0, "Resume evicts the failed solve so it can run again");
Check(queue._executionPlan.Refreshed && queue._executionPlan._planningSnapshot.Recipes.Count == 1, "Resume replans only unfinished final crafts");
Check(queue._executionPlan._planningSnapshot.Recipes[0].RecipeId == 1136 && queue._executionPlan._planningSnapshot.Recipes[0].Quantity == 2, "Completed final craft is not repeated; remaining quantity preserved");
Check(queue._executionPlan._planningSnapshot.SkipIfEnough && !queue._executionPlan._planningSnapshot.SkipFinalIfEnough, "Resume consumes manually acquired intermediates without counting completed finals twice");
Check(CraftingGatherBridge.Starts == 1 && queue._currentState == QueueState.WaitingForGather, "Acquisition restarts once");
queue.Resume();
Check(CraftingGatherBridge.Starts == 1, "Resume on active queue has no effect");
queue.PauseFailedRaphaelItem(new(1047, false));
Check(queue._paused && queue._currentQueueIndex == 0, "Unresolved failure pauses again without skipping");
var single = new QueueHarness();
single._executionPlan.Queue = [new(1136, true)];
single._currentQueueIndex = 0;
single.PauseFailedRaphaelItem(new(1136, true));
Check(single._paused && single._currentQueueIndex == 0, "Failed final craft also stays blocked");
var fr = CraftBlockerMessage.Build("Madrier d’if", "Menuisier", 6, 21, 39, 9, 180, 0, 0, true, true);
Check(fr.Contains("Menuisier level 6") && fr.Contains("recipe level 21") && fr.Contains("manually"), "Low-level blocker identifies job, levels and manual alternative");
Check(!fr.Contains("requis") && !fr.Contains("panicked"), "Displayed recipe level is not invented as a hard requirement");
var stats = CraftBlockerMessage.Build("Item", "Carpenter", 100, 100, 250, 180, 300, 300, 200, true, false);
Check(stats.Contains("250/300 (missing 50)") && stats.Contains("180/200 (missing 20)"), "Known stat requirements show exact deficits");
var other = CraftBlockerMessage.Build("Objet", "Alchimiste", 100, 20, 500, 400, 300, 0, 0, false, true);
Check(!other.Contains("below") && !other.Contains("manually"), "Solver failure does not invent a level deficit or a final-item Resume promise");
var repairQueue = new QueueHarness { _currentState = QueueState.Repairing };
repairQueue._tasks.Add(() => { repairQueue.TransitionFromRepairComplete(); return CraftingTasks.TaskResult.Done; });
repairQueue.ProcessTasks();
Check(repairQueue._paused && repairQueue._currentQueueIndex == 1, "Incomplete repair pauses without losing the current craft");
Check(repairQueue._tasks.Count == 0 && repairQueue._currentState == QueueState.WaitingForJobSwitch, "Pausing from inside a repair callback safely clears tasks");
Check(ForkVulcanWorkflowSupport.Events == 1 && repairQueue._pauseReason == "Repair needed", "Repair blocker stays visible and enters activity history");
repairQueue.Resume();
Check(!repairQueue._paused && repairQueue._currentQueueIndex == 1 && repairQueue._currentState == QueueState.WaitingForJobSwitch, "Repair Resume preserves progress and rechecks the job");
repairQueue._currentState = QueueState.Repairing;
repairQueue._tasks.Add(() => CraftingTasks.TaskResult.Abort);
repairQueue.ProcessTasks();
Check(repairQueue._paused && repairQueue._currentQueueIndex == 1, "Aborted repair pauses rather than retrying every frame");
var repaired = new QueueHarness { RepairNeeded = false, _currentState = QueueState.Repairing };
repaired._tasks.Add(() => { repaired.TransitionFromRepairComplete(); return CraftingTasks.TaskResult.Done; });
repaired.ProcessTasks();
Check(!repaired._paused && repaired._tasks.Count == 0 && repaired._currentState == QueueState.WaitingForJobSwitch, "Successful repair continues normally");
var retainerPause = new QueueHarness();
retainerPause._tasks.Add(() => { retainerPause._paused = true; return CraftingTasks.TaskResult.Done; });
retainerPause._tasks.Add(() => throw new Exception("Must not execute tasks after pause"));
retainerPause.ProcessTasks();
Check(retainerPause._tasks.Count == 1, "Pause without clearing consumes its completed callback once and stops processing");
var repairText = CraftBlockerMessage.BuildRepair("Couturier", 10, 20);
Check(repairText.Contains("Couturier") && repairText.Contains("10%") && repairText.Contains("20%") && repairText.Contains("Resume"), "Repair explanation identifies equipped job, condition and next action");
var missing = CraftBlockerMessage.BuildMaterials("Elm Lumber", "Elm Log", 3, 1, 0);
Check(missing.Contains("Obtain 2 more") && !missing.Contains("RecipeNote") && !missing.Contains("item 50"), "Missing-material message gives the actual deficit without internal jargon");
var quality = CraftBlockerMessage.BuildMaterials("Item", "Material", 3, 0, 3);
Check(quality.Contains("quality") && !quality.Contains("Obtain"), "Enough items with incompatible quality do not produce a false shortage");
Check(RecipeSelectionGuard.Matches(1037, 100, 1037, 100, [(200, 3)], [(200, 3)]), "Correct recipe and ingredients accepted");
Check(!RecipeSelectionGuard.Matches(1037, 100, 1037, 100, [(200, 3)], [(5056, 3)]), "Reported bronze-ingot mismatch rejected before inventory checks");
Check(!RecipeSelectionGuard.Matches(1037, 100, 43, 100, [(200, 3)], [(200, 3)]), "Different recipe rejected even if ingredients match");
Check(!RecipeSelectionGuard.Matches(1037, 100, 1037, 101, [(200, 3)], [(200, 3)]), "Stale result item rejected");
Check(!RecipeSelectionGuard.Matches(1037, 100, 1037, 100, [(200, 3)], [(200, 1)]), "Stale ingredient quantity rejected");
Check(!RecipeSelectionGuard.Matches(1037, 100, 1037, 100, [(200, 3)], []), "Empty ingredients during refresh are not considered ready");
SelectionHarness.Ready = false;
Check(!SelectionHarness.EnsureExpectedRecipeSelected() && AgentRecipeNote.Opens == 1, "Mismatch reopens requested recipe without reporting missing materials");
SelectionHarness.EnsureExpectedRecipeSelected();
Check(AgentRecipeNote.Opens == 1 && SelectionHarness._lastPreparationFailure == null, "Recipe reopen is throttled");
SelectionHarness._recipeMismatchSince = DateTime.UtcNow.AddSeconds(-3);
SelectionHarness.EnsureExpectedRecipeSelected();
Check(SelectionHarness._lastPreparationFailure?.Reason == CraftPreparationFailureReason.RecipeSelectionMismatch, "Persistent mismatch produces selection failure, not material shortage");
SelectionHarness.Ready = true;
Check(SelectionHarness.EnsureExpectedRecipeSelected() && SelectionHarness._recipeMismatchSince == DateTime.MinValue, "Matching selection ends recovery wait");
Console.WriteLine($"{passed} crafting blocker regression tests passed.");

record RaphaelSolveRequest(uint RecipeId) { public string GetKey() => RecipeId.ToString(); }
class CraftingListItem(uint id, bool original) { public uint RecipeId = id; public bool IsOriginalRecipe = original; public int Quantity = 1; public Options Options = new(); }
class Options { public bool Skipping = false; }
class Snapshot { public List<CraftingListItem> Recipes = [new(50, true), new(1136, true)]; public bool SkipIfEnough, SkipFinalIfEnough = true; }
partial class PlanHarness {
    public List<CraftingListItem> Queue = [new(50, true), new(1047, false), new(1136, true), new(1136, true)];
    public Snapshot _planningSnapshot = new(); public bool Refreshed;
    public void RefreshFromCurrentInventory() => Refreshed = true;
}
enum QueueState { Repairing, WaitingForGather, WaitingForJobSwitch, WaitingForRaphaelSolution, WaitingForManualMaterials, NavigatingToRetainerBell, WithdrawingFromRetainer, Crafting }
partial class QueueHarness {
    public List<Func<CraftingTasks.TaskResult>> _tasks = [];
    public bool RepairNeeded = true;
    bool NeedsRepair() => RepairNeeded;
    string BuildRepairPauseReason() => "Repair needed";
    void Pause(string reason) { _paused = true; _pauseReason = reason; _tasks.Clear(); }

    public bool _paused, _craftBlocked, _pausedDuringGather;
    public int _currentQueueIndex = 1, _currentProcessedRecipeId, _currentProcessedRecipeCount, _currentProcessedRecipeTotal, _jobSwitchRequestedFor;
    public QueueState _currentState = QueueState.WaitingForRaphaelSolution;
    public string _pauseReason = "";
    public RaphaelSolveRequest? _blockedRaphaelRequest;
    public Coordinator _raphaelCoordinator = new();
    public Dictionary<string, RaphaelSolveRequest> _enqueuedRaphaelRequests = new() { ["1047"] = new(1047) };
    public PlanHarness _executionPlan = new();
    public Dictionary<uint, int> MaterialTargets = new();
    public Action<QueueState>? StateChanged = null;
    public object? _retainerExecutor = null;
    RaphaelSolveRequest BuildRaphaelRequestForItem(CraftingListItem item) => new(item.RecipeId);
    void PauseForCraftBlocker(CraftingListItem item, bool failed) { _craftBlocked = true; _paused = true; }
    void QueueRetainerBellNavigationTasks() => throw new Exception("Unexpected retainer navigation");
    void QueueRetainerWithdrawalTasks() => throw new Exception("Unexpected retainer withdrawal");
    void QueueRetainerWithdrawalExecutionTasks() => throw new Exception("Unexpected retainer execution");
}
class Coordinator {
    public int Removed;
    public bool HasFailedSolution(RaphaelSolveRequest r, out string? reason) { reason = "NoSolution"; return true; }
    public void RemoveCachedSolution(RaphaelSolveRequest r) => Removed++;
}
namespace GatherBuddy { static class Log { public static void Warning(string s) {} public static void Information(string s) {} public static void Debug(string s) {} } static class AutoGather { public static bool Enabled; } }
static class YesAlready { public static void Lock() {} }
class GatherList { public List<int> Items = []; }
static class CraftingGatherBridge { public static int Starts; public static void CreateGatherListForMissingIngredients(Dictionary<uint, int> m) => Starts++; public static GatherList? GetTemporaryGatherList() => null; }
static class CraftingGameInterop { public enum CraftState { IdleNormal } public static CraftState CurrentState = CraftState.IdleNormal; }


static class CraftingTasks {
    public enum TaskResult { Done, Retry, Abort }
    public static void ResetRepairState() {}
}
static class ForkVulcanWorkflowSupport { public static int Events; public static void AddActivity(string reason, VulcanActivityKind kind) => Events++; }
enum VulcanActivityKind { Warning }

partial class SelectionHarness {
    public static bool Ready;
    public static DateTime _recipeMismatchSince = DateTime.MinValue, _lastRecipeReopen = DateTime.MinValue;
    public static uint? _currentRecipeId = 1037;
    public static CraftPreparationFailure? _lastPreparationFailure;
    static bool IsExpectedRecipeSelected() => Ready;
}
enum CraftPreparationFailureReason { RecipeSelectionMismatch }
record CraftPreparationFailure(uint RecipeId, CraftPreparationFailureReason Reason, uint ItemId, int Needed, int NQ, int HQ, string Details);
unsafe struct AgentRecipeNote {
    static readonly nint Pointer = System.Runtime.InteropServices.Marshal.AllocHGlobal(1);
    public static int Opens;
    public static AgentRecipeNote* Instance() => (AgentRecipeNote*)Pointer;
    public void OpenRecipeByRecipeId(uint id) => Opens++;
}
