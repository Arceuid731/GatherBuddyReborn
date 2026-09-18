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
var fr = CraftBlockerMessage.Build(true, "Madrier d’if", "Menuisier", 6, 21, 39, 9, 180, 0, 0, true, true);
Check(fr.Contains("Menuisier niv. 6") && fr.Contains("recette niv. 21") && fr.Contains("manuellement"), "Low-level blocker identifies job, levels and manual alternative");
Check(!fr.Contains("requis") && !fr.Contains("panicked"), "Displayed recipe level is not invented as a hard requirement");
var stats = CraftBlockerMessage.Build(false, "Item", "Carpenter", 100, 100, 250, 180, 300, 300, 200, true, false);
Check(stats.Contains("250/300 (missing 50)") && stats.Contains("180/200 (missing 20)"), "Known stat requirements show exact deficits");
var other = CraftBlockerMessage.Build(true, "Objet", "Alchimiste", 100, 20, 500, 400, 300, 0, 0, false, true);
Check(!other.Contains("inférieur") && !other.Contains("manuellement"), "Solver failure does not invent a level deficit or a final-item Resume promise");
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
enum QueueState { WaitingForGather, WaitingForJobSwitch, WaitingForRaphaelSolution, WaitingForManualMaterials, NavigatingToRetainerBell, WithdrawingFromRetainer, Crafting }
partial class QueueHarness {
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

