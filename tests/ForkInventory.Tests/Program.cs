using GatherBuddy.AutoGather.Extensions;
using GatherBuddy.Interfaces;
using GatherBuddy.Plugin;
using GatherBuddy.Crafting;

var item = new Item(42);
var other = new Item(99);
var passed = 0;
void Check(int actual, int expected, string name)
{
    if (actual != expected) throw new Exception($"{name}: expected {expected}, got {actual}");
    Console.WriteLine($"PASS {name}");
    passed++;
}
Check(item.GetTotalCount(), 100, "Normal gathering includes retainers");
Check(item.GetTotalCount(false), 3, "Upstream bag-only flag excludes retainers");
CraftingGatherBridge.List = new() { Enabled = true, Items = [item] };
Check(item.GetTotalCount(), 3, "Vulcan target uses bags through legacy callers");
Check(item.GetTotalCount(true), 3, "Vulcan target uses bags through new upstream callers");
Check(item.GetTotalCount(false), 3, "Vulcan target respects explicit bag-only mode");
Check(other.GetTotalCount(), 100, "Unrelated target retains normal inventory policy");
CraftingGatherBridge.List.Enabled = false;
Check(item.GetTotalCount(), 100, "Disabled Vulcan list does not affect regular gathering");
CraftingGatherBridge.List = null;
GatherBuddy.GatherBuddy.Config.AutoGatherConfig.CheckRetainers = false;
Check(item.GetTotalCount(), 3, "User retainer preference remains authoritative");
GatherBuddy.GatherBuddy.Config.AutoGatherConfig.CheckRetainers = true;
AllaganTools.Enabled = false;
Check(item.GetTotalCount(), 3, "Unavailable Allagan Tools falls back to bags");
item.ItemData.IsCollectable = true;
Check(item.GetTotalCount(false), 5, "Collectables include the collectable inventory count");
Console.WriteLine($"{passed} inventory regression tests passed.");

record Item(uint ItemId) : IGatherable
{
    public ItemData ItemData { get; } = new();
}
namespace GatherBuddy.Interfaces
{
    public interface IGatherable { uint ItemId { get; } ItemData ItemData { get; } }
    public class ItemData { public bool IsCollectable { get; set; } }
}
namespace GatherBuddy.Helpers { internal class NamespaceStub; }
namespace GatherBuddy
{
    public static class GatherBuddy { public static Config Config = new(); }
    public class Config { public GatherConfig AutoGatherConfig = new(); }
    public class GatherConfig { public bool CheckRetainers = true; }
}
namespace GatherBuddy.Plugin
{
    public static class AllaganTools
    {
        public static bool Enabled = true;
        public static uint ItemCountOwned(uint itemId, bool include, uint[] types) => 100;
    }
}
namespace GatherBuddy.Crafting
{
    public class GatherList { public bool Enabled; public List<IGatherable> Items = []; }
    public static class CraftingGatherBridge
    {
        public static GatherList? List;
        public static GatherList? GetTemporaryGatherList() => List;
    }
}
namespace FFXIVClientStructs.FFXIV.Client.Game
{
    public enum InventoryType : uint { RetainerCrystals, RetainerPage1, RetainerPage2, RetainerPage3, RetainerPage4, RetainerPage5, RetainerPage6, RetainerPage7, Inventory1, Inventory2, Inventory3, Inventory4, Crystals }
    public unsafe struct InventoryManager
    {
        private static readonly nint Pointer = System.Runtime.InteropServices.Marshal.AllocHGlobal(sizeof(InventoryManager));
        public static InventoryManager* Instance() => (InventoryManager*)Pointer;
        public int GetInventoryItemCount(uint item, bool hq, bool equip, bool armory, int collectable) => collectable == 0 ? 3 : 2;
    }
}
