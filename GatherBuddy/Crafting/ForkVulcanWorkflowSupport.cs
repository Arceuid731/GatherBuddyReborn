using System;
using System.Collections.Generic;
using System.Linq;
using FFXIVClientStructs.FFXIV.Client.Game;
using GatherBuddy.AutoGather.Lists;
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
    public bool Complete => Missing == 0;
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
    private const int MaxUnchangedGatherRecoveries = 1;
    private const int MaxTotalGatherRecoveries = 3;
    private static readonly object Sync = new();
    private static readonly List<VulcanActivityEntry> Activity = [];
    private static List<VulcanMaterialBlocker> _manualBlockers = [];
    private static List<VulcanGatherTarget> _gatherTargets = [];
    private static string _lastActivityMessage = string.Empty;
    private static DateTime _lastActivityAt = DateTime.MinValue;
    private static string _lastGatherRecoverySignature = string.Empty;
    private static int _unchangedGatherRecoveries;
    private static int _totalGatherRecoveries;

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

    /// <summary>
    /// Same blocker set as when the queue paused, but bag counts are re-read on
    /// every UI frame so manually looted/withdrawn items are reflected immediately.
    /// </summary>
    public static IReadOnlyList<VulcanMaterialBlocker> GetLiveManualBlockers()
        => ManualBlockers
            .Select(blocker => blocker with { Available = GetInventoryCount(blocker.ItemId) })
            .ToList();

    public static void Reset()
    {
        lock (Sync)
        {
            Activity.Clear();
            _manualBlockers = [];
            _gatherTargets = [];
            _lastActivityMessage = string.Empty;
            _lastActivityAt = DateTime.MinValue;
            _lastGatherRecoverySignature = string.Empty;
            _unchangedGatherRecoveries = 0;
            _totalGatherRecoveries = 0;
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

    /// <summary>
    /// `GameData.Gatherables` is built from the game's GatheringItem sheet and can
    /// contain placeholder/orphan rows that have no gathering node at all. Those
    /// rows must never be fed to AutoGather: it has nowhere to go and completes or
    /// errors immediately. A real automatic target must have a concrete node/spot.
    /// </summary>
    public static bool IsActuallyAutoGatherable(uint itemId)
    {
        if (GatherBuddy.GameData.Gatherables.TryGetValue(itemId, out var gatherable))
            return gatherable.NodeList.Count > 0;

        if (GatherBuddy.GameData.Fishes.TryGetValue(itemId, out var fish))
            return fish.FishingSpots.Count > 0;

        return false;
    }

    public static bool TryAddAutoGatherTarget(AutoGatherList list, uint itemId, int quantity)
    {
        if (quantity <= 0)
            return false;

        if (GatherBuddy.GameData.Gatherables.TryGetValue(itemId, out var gatherable)
         && gatherable.NodeList.Count > 0)
            return list.Add(gatherable, (uint)quantity);

        if (GatherBuddy.GameData.Fishes.TryGetValue(itemId, out var fish)
         && fish.FishingSpots.Count > 0)
            return list.Add(fish, (uint)quantity);

        return false;
    }

    /// <summary>
    /// Classification used by the crafting acquisition pipeline. Do not trust a raw
    /// GatheringItem/FishParameter row as proof that AutoGather can obtain it; require
    /// a real location. Phantom gather rows then fall through to drop/vendor/manual.
    /// </summary>
    public static MaterialSource ClassifyForAcquisition(uint itemId)
    {
        if (GatherBuddy.GameData.Gatherables.TryGetValue(itemId, out var gatherable)
         && gatherable.NodeList.Count > 0)
            return MaterialSource.Gatherable;

        if (GatherBuddy.GameData.Fishes.TryGetValue(itemId, out var fish)
         && fish.FishingSpots.Count > 0)
            return MaterialSource.Fish;

        if (MobDropInfoCache.IsKnownDropItem(itemId))
            return MaterialSource.Drop;

        var source = MaterialSourceClassifier.Classify(itemId);
        // These two values can come from location-less game-data rows. At this point
        // we already proved no real node/spot exists, so treating them as automatic
        // would recreate the honk/rebuild loop.
        return source is MaterialSource.Gatherable or MaterialSource.Fish
            ? MaterialSource.Other
            : source;
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
    /// Allows a bounded recovery if AutoGather reports completion while real node
    /// materials are still missing. An unchanged deficit may be retried once only;
    /// even with changing counts, the whole queue is capped at three recovery passes.
    /// This makes an AutoGather/plugin data failure impossible to spin/honk forever.
    /// </summary>
    public static bool TryRegisterGatherRecovery(
        IReadOnlyDictionary<uint, int> materials,
        out string outstandingSummary,
        out string stopReason)
    {
        var outstanding = materials
            .Where(entry => entry.Value > GetInventoryCount(entry.Key) && IsActuallyAutoGatherable(entry.Key))
            .Select(entry => new
            {
                entry.Key,
                Needed = entry.Value,
                Have = GetInventoryCount(entry.Key),
                Name = GetItemName(entry.Key),
            })
            .OrderBy(entry => entry.Key)
            .ToList();

        outstandingSummary = string.Join(", ", outstanding.Select(entry => $"{entry.Name} x{Math.Max(0, entry.Needed - entry.Have)}"));
        var signature = string.Join("|", outstanding.Select(entry => $"{entry.Key}:{entry.Have}/{entry.Needed}"));

        lock (Sync)
        {
            if (string.Equals(signature, _lastGatherRecoverySignature, StringComparison.Ordinal))
                _unchangedGatherRecoveries++;
            else
            {
                _lastGatherRecoverySignature = signature;
                _unchangedGatherRecoveries = 1;
            }
            _totalGatherRecoveries++;

            if (_unchangedGatherRecoveries <= MaxUnchangedGatherRecoveries
             && _totalGatherRecoveries <= MaxTotalGatherRecoveries)
            {
                stopReason = string.Empty;
                return true;
            }
        }

        stopReason = string.IsNullOrWhiteSpace(outstandingSummary)
            ? "AutoGather ended without satisfying the crafting gather plan. Vulcan paused to prevent an infinite retry loop. Check the gather list and press Resume after resolving the issue."
            : $"AutoGather ended without making enough progress on {outstandingSummary}. Vulcan paused to prevent an infinite retry/honk loop. Resolve the remaining material(s), then press Resume.";
        return false;
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
            combined[itemId] = combined.GetValueOrDefault(itemId) + needed;

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

            var source = ClassifyForAcquisition(itemId);
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

            if (IsActuallyAutoGatherable(itemId))
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
            if (IsActuallyAutoGatherable(itemId))
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
        var outstanding = blockers.Where(blocker => !blocker.Complete).ToList();
        if (outstanding.Count == 0)
            return "Manual materials acquired. Press Resume to continue.";

        var preview = string.Join(", ", outstanding.Take(3).Select(blocker => $"{blocker.ItemName} x{blocker.Missing}"));
        if (outstanding.Count > 3)
            preview += $", +{outstanding.Count - 3} more";
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

        // The mob cache initializes asynchronously. A location-less GatheringItem
        // can initially be classified as Other and become a known monster drop a
        // moment later, so resolve that dynamically for the UI.
        var dropInfo = MobDropInfoCache.GetDropInfoForItem(blocker.ItemId);
        var effectiveDrop = blocker.Source == MaterialSource.Drop || dropInfo.HasData;
        if (!effectiveDrop)
        {
            lines.Add(GetSourceLabel(blocker.Source));
            return lines;
        }

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
