using System;
using System.Collections.Generic;
using System.Linq;
using FFXIVClientStructs.FFXIV.Client.Game;
using GatherBuddy.Plugin;
using Lumina.Excel.Sheets;

namespace GatherBuddy.Crafting;

public enum VulcanActivityKind
{
    Info,
    Success,
    Gather,
    Retainer,
    Warning,
    Error,
}

public readonly record struct VulcanActivityEntry(
    DateTime Timestamp,
    VulcanActivityKind Kind,
    string Message);

public sealed record VulcanMaterialBlocker(
    uint ItemId,
    string ItemName,
    int Needed,
    int Available,
    int RetainerAvailable,
    MaterialSource Source)
{
    public int Missing => Math.Max(0, Needed - Available);
}

public sealed record VulcanGatherTarget(
    uint ItemId,
    string ItemName,
    int TargetQuantity);

public sealed record VulcanGatherTargetStatus(
    uint ItemId,
    string ItemName,
    int CurrentQuantity,
    int TargetQuantity)
{
    public int Remaining => Math.Max(0, TargetQuantity - CurrentQuantity);
    public bool Complete => CurrentQuantity >= TargetQuantity;
}

/// <summary>
/// Fork-local workflow diagnostics and material acquisition guardrails for Vulcan.
/// Kept separate from upstream classes so the fork patch remains easy to rebase.
/// </summary>
public static class ForkVulcanWorkflowSupport
{
    private const int MaxActivityEntries = 40;
    private static readonly object Sync = new();
    private static readonly List<VulcanActivityEntry> Activity = [];
    private static List<VulcanMaterialBlocker> _manualBlockers = [];
    private static List<VulcanGatherTarget> _gatherTargets = [];
    private static string _lastActivityMessage = string.Empty;
    private static DateTime _lastActivityAt = DateTime.MinValue;

    public static IReadOnlyList<VulcanActivityEntry> RecentActivity
    {
        get
        {
            lock (Sync)
                return Activity.ToArray();
        }
    }

    public static IReadOnlyList<VulcanMaterialBlocker> ManualBlockers
    {
        get
        {
            lock (Sync)
                return _manualBlockers.ToArray();
        }
    }

    public static void Reset()
    {
        lock (Sync)
        {
            Activity.Clear();
            _manualBlockers = [];
            _gatherTargets = [];
            _lastActivityMessage = string.Empty;
            _lastActivityAt = DateTime.MinValue;
        }
        MobDropInfoCache.EnsureInitializeStarted();
    }

    public static void AddActivity(string message, VulcanActivityKind kind = VulcanActivityKind.Info)
    {
        if (string.IsNullOrWhiteSpace(message))
            return;

        var now = DateTime.Now;
        lock (Sync)
        {
            if (string.Equals(message, _lastActivityMessage, StringComparison.Ordinal)
             && (now - _lastActivityAt) < TimeSpan.FromMilliseconds(750))
                return;

            Activity.Add(new VulcanActivityEntry(now, kind, message));
            if (Activity.Count > MaxActivityEntries)
                Activity.RemoveRange(0, Activity.Count - MaxActivityEntries);
            _lastActivityMessage = message;
            _lastActivityAt = now;
        }
    }

    public static void UpdateGatherTargets(IEnumerable<(uint ItemId, int TargetQuantity)> targets)
    {
        var itemSheet = Dalamud.GameData.GetExcelSheet<Item>();
        var planned = targets
            .Where(target => target.ItemId > 0 && target.TargetQuantity > 0)
            .GroupBy(target => target.ItemId)
            .Select(group =>
            {
                var targetQuantity = group.Max(entry => entry.TargetQuantity);
                var itemName = itemSheet != null && itemSheet.TryGetRow(group.Key, out var item)
                    ? item.Name.ExtractText()
                    : $"Item {group.Key}";
                return new VulcanGatherTarget(group.Key, itemName, targetQuantity);
            })
            .OrderBy(target => target.ItemName, StringComparer.OrdinalIgnoreCase)
            .ToList();

        lock (Sync)
            _gatherTargets = planned;
    }

    public static IReadOnlyList<VulcanGatherTargetStatus> GetGatherTargetStatus()
    {
        VulcanGatherTarget[] targets;
        lock (Sync)
            targets = _gatherTargets.ToArray();

        return targets
            .Select(target => new VulcanGatherTargetStatus(
                target.ItemId,
                target.ItemName,
                GetInventoryCount(target.ItemId),
                target.TargetQuantity))
            .ToList();
    }

    public static string BuildGatherPlanSummary(int maxItems = 5)
    {
        var pending = GetGatherTargetStatus().Where(target => !target.Complete).ToList();
        if (pending.Count == 0)
            return string.Empty;

        var summary = string.Join(", ", pending.Take(maxItems).Select(target => $"{target.ItemName} x{target.Remaining}"));
        if (pending.Count > maxItems)
            summary += $", +{pending.Count - maxItems} more";
        return summary;
    }

    public static void ClearGatherTargets()
    {
        lock (Sync)
            _gatherTargets = [];
    }

    /// <summary>
    /// Returns whether travelling to a retainer bell can actually satisfy at least
    /// one current inventory deficit. If AllaganTools is not ready yet we preserve
    /// upstream behaviour rather than incorrectly skipping a potentially useful restock.
    /// </summary>
    public static bool HasUsefulRetainerWork(
        IReadOnlyDictionary<uint, int> materialTargets,
        IReadOnlyDictionary<uint, int> precraftTargets)
    {
        if (!AllaganTools.Enabled)
            return false;

        var combined = new Dictionary<uint, int>(materialTargets);
        foreach (var (itemId, needed) in precraftTargets)
            combined[itemId] = Math.Max(combined.GetValueOrDefault(itemId), needed);

        if (combined.Count == 0)
            return false;

        if (!RetainerItemQuery.IsReady)
            return true;

        RetainerItemSnapshot snapshot;
        try
        {
            snapshot = RetainerItemQuery.CreateSnapshot(combined.Keys);
        }
        catch (Exception ex)
        {
            GatherBuddy.Log.Debug($"[ForkVulcanWorkflowSupport] Retainer preflight failed, preserving restock attempt: {ex.Message}");
            return true;
        }

        foreach (var (itemId, targetQuantity) in combined)
        {
            var missing = Math.Max(0, targetQuantity - GetInventoryCount(itemId));
            if (missing <= 0)
                continue;
            if (snapshot.GetTotalCount(itemId) > 0)
                return true;
        }

        return false;
    }

    public static IReadOnlyList<VulcanMaterialBlocker> UpdateManualBlockers(
        IReadOnlyDictionary<uint, int> materials,
        bool retainerRestock)
    {
        MobDropInfoCache.EnsureInitializeStarted();
        var itemSheet = Dalamud.GameData.GetExcelSheet<Item>();
        var deficits = new List<(uint ItemId, int Needed, int Available, MaterialSource Source)>();

        foreach (var (itemId, needed) in materials)
        {
            if (needed <= 0)
                continue;

            var available = GetInventoryCount(itemId);
            if (available >= needed)
                continue;

            var source = MaterialSourceClassifier.Classify(itemId);
            if (source is MaterialSource.Gatherable or MaterialSource.Fish)
                continue;

            deficits.Add((itemId, needed, available, source));
        }

        RetainerItemSnapshot retainerSnapshot = RetainerItemSnapshot.Empty;
        if (deficits.Count > 0 && AllaganTools.Enabled)
        {
            try
            {
                retainerSnapshot = RetainerItemQuery.CreateSnapshot(deficits.Select(deficit => deficit.ItemId));
            }
            catch (Exception ex)
            {
                GatherBuddy.Log.Debug($"[ForkVulcanWorkflowSupport] Could not read retainer counts for blockers: {ex.Message}");
            }
        }

        var blockers = new List<VulcanMaterialBlocker>(deficits.Count);
        foreach (var deficit in deficits)
        {
            var itemName = itemSheet != null && itemSheet.TryGetRow(deficit.ItemId, out var item)
                ? item.Name.ExtractText()
                : $"Item {deficit.ItemId}";
            var retainerAvailable = retainerSnapshot.GetCountNQ(deficit.ItemId) + retainerSnapshot.GetCountHQ(deficit.ItemId);
            blockers.Add(new VulcanMaterialBlocker(
                deficit.ItemId,
                itemName,
                deficit.Needed,
                deficit.Available,
                retainerAvailable,
                deficit.Source));
        }

        blockers.Sort((left, right) => string.Compare(left.ItemName, right.ItemName, StringComparison.OrdinalIgnoreCase));
        lock (Sync)
            _manualBlockers = blockers;
        return blockers;
    }

    public static void ClearManualBlockers()
    {
        lock (Sync)
            _manualBlockers = [];
    }

    public static bool HasOutstandingGatherables(IReadOnlyDictionary<uint, int> materials)
    {
        foreach (var (itemId, needed) in materials)
        {
            if (needed <= GetInventoryCount(itemId))
                continue;

            var source = MaterialSourceClassifier.Classify(itemId);
            if (source is MaterialSource.Gatherable or MaterialSource.Fish)
                return true;
        }
        return false;
    }

    public static int CountOutstandingGatherables(IReadOnlyDictionary<uint, int> materials)
    {
        var count = 0;
        foreach (var (itemId, needed) in materials)
        {
            if (needed <= GetInventoryCount(itemId))
                continue;
            var source = MaterialSourceClassifier.Classify(itemId);
            if (source is MaterialSource.Gatherable or MaterialSource.Fish)
                count++;
        }
        return count;
    }

    public static string GetItemName(uint itemId)
    {
        var itemSheet = Dalamud.GameData.GetExcelSheet<Item>();
        return itemSheet != null && itemSheet.TryGetRow(itemId, out var item)
            ? item.Name.ExtractText()
            : $"Item {itemId}";
    }

    public static string BuildPauseReason(IReadOnlyList<VulcanMaterialBlocker> blockers)
    {
        if (blockers.Count == 0)
            return string.Empty;

        var preview = string.Join(", ", blockers.Take(3).Select(blocker => $"{blocker.ItemName} x{blocker.Missing}"));
        if (blockers.Count > 3)
            preview += $", +{blockers.Count - 3} more";
        return $"Manual materials required: {preview}. Acquire or withdraw them, then press Resume.";
    }

    public static string GetSourceLabel(MaterialSource source)
        => source switch
        {
            MaterialSource.Drop => "Monster drop",
            MaterialSource.GilVendor => "Gil vendor",
            MaterialSource.Scrip => "Scrip exchange",
            MaterialSource.SpecialCurrency => "Special currency",
            MaterialSource.Craftable => "Craftable component",
            MaterialSource.Gatherable => "Gatherable",
            MaterialSource.Fish => "Fishing",
            _ => "Manual / unknown source",
        };

    public static IReadOnlyList<string> GetSourceHintLines(VulcanMaterialBlocker blocker)
    {
        var lines = new List<string>();

        if (blocker.RetainerAvailable > 0)
            lines.Add($"Retainers: {blocker.RetainerAvailable} available (enable Restock from Retainers or withdraw manually)." );

        if (blocker.Source != MaterialSource.Drop)
        {
            lines.Add(GetSourceLabel(blocker.Source));
            return lines;
        }

        var dropInfo = MobDropInfoCache.GetDropInfoForItem(blocker.ItemId);
        if (!dropInfo.HasData)
        {
            lines.Add(MobDropInfoCache.IsInitialized
                ? "Monster drop — no spawn location data available."
                : "Monster drop — location data is still loading.");
            return lines;
        }

        const int maxLocations = 3;
        var locationLines = dropInfo.Mobs
            .SelectMany(mob => mob.Zones.SelectMany(zone =>
                zone.Clusters.Select(cluster => (Mob: mob, Zone: zone, Cluster: cluster))))
            .OrderBy(entry => entry.Zone.ZoneName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(entry => entry.Mob.MobName, StringComparer.OrdinalIgnoreCase)
            .Take(maxLocations)
            .Select(entry =>
            {
                var mobName = string.IsNullOrWhiteSpace(entry.Mob.MobName) ? "Unknown monster" : entry.Mob.MobName;
                if (entry.Cluster.HasCoordinates)
                    return $"{mobName} — {entry.Zone.ZoneName} (X {entry.Cluster.MapX:F1}, Y {entry.Cluster.MapY:F1})";
                return $"{mobName} — {entry.Zone.ZoneName}";
            })
            .ToList();

        lines.AddRange(locationLines);
        if (dropInfo.ClusterCount > maxLocations)
            lines.Add($"+{dropInfo.ClusterCount - maxLocations} other known spawn area(s)");
        return lines;
    }

    private static unsafe int GetInventoryCount(uint itemId)
    {
        try
        {
            var inventory = InventoryManager.Instance();
            if (inventory == null)
                return 0;
            return (int)(inventory->GetInventoryItemCount(itemId, false, false, false)
                       + inventory->GetInventoryItemCount(itemId, true, false, false));
        }
        catch
        {
            return 0;
        }
    }
}
