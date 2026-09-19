using System;
using System.IO;
using GatherBuddy.AutoGather.Lists;
using GatherBuddy.Plugin;
using GatherBuddy.SeFunctions;
using Lumina.Excel.Sheets;

namespace GatherBuddy.AutoGather;

public partial class AutoGather
{
    private bool TryPauseForMissingFishingBait(GatherTarget target)
    {
        if (!Enabled || target.Fish == null || target.Fish.IsSpearFish
            || !GatherBuddy.Config.AutoGatherConfig.UseAutoHook || !AutoHook.Enabled)
            return false;

        try
        {
            var directory = Dalamud.PluginInterface.ConfigDirectory.Parent?.FullName;
            if (directory == null) return false;
            var path = Path.Combine(directory, "AutoHook.json");
            if (!File.Exists(path)) return false;
            var baitId = FishingBaitRequirement.Resolve(File.ReadAllText(path),
                _currentAutoHookPresetName, _currentAutoHookTargetPresetName,
                _isUsingAutoHookGlobalPreset, GatherBuddy.CurrentBait.Current);
            if (baitId == 0 || CurrentBait.HasItem(baitId) > 0) return false;

            var baitName = Dalamud.GameData.GetExcelSheet<Item>().TryGetRow(baitId, out var bait)
                ? bait.Name.ExtractText() : $"Item {baitId}";
            var fishName = target.Fish.Name[GatherBuddy.Language];
            var reason = $"Missing bait for {fishName}: {baitName}. Buy or obtain {baitName} and keep it in your main inventory";
            AutoHook.SetAutoStartFishing?.Invoke(false);
            AutoHook.SetPluginState?.Invoke(false);
            AbortAutoGather(reason);
            return true;
        }
        catch (Exception ex)
        {
            GatherBuddy.Log.Debug($"[AutoGather] Could not check the active fishing bait: {ex.Message}");
            return false;
        }
    }
}
