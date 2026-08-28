using System;
using System.Collections.Generic;
using System.Linq;
using GatherBuddy.Vulcan.Vendors;
using Lumina.Excel.Sheets;

namespace GatherBuddy.Crafting;

public sealed record VulcanVendorPurchaseHint(
    uint ItemId,
    string ItemName,
    int Missing,
    uint UnitCost,
    string CurrencyName)
{
    public long TotalCost => (long)Missing * UnitCost;
}

public sealed record VulcanVendorStopHint(
    uint NpcId,
    string NpcName,
    string ZoneName,
    float? MapX,
    float? MapY,
    IReadOnlyList<VulcanVendorPurchaseHint> Purchases)
{
    public long TotalGilCost => Purchases.Sum(purchase => purchase.TotalCost);
}

/// <summary>
/// Fork-local supply planner for crafting materials that can be bought from gil vendors.
/// It deliberately plans against the whole outstanding material set and greedily groups
/// items by NPC, so one vendor visit buys every useful material that NPC can provide.
/// </summary>
public static class ForkVulcanSupplyPlan
{
    public static bool VendorDataLoading
        => !VendorShopResolver.IsInitialized && VendorShopResolver.IsInitializing;

    public static bool IsGilVendorPreferred(uint itemId)
        => MaterialSourceClassifier.Classify(itemId, preferVendors: true) == MaterialSource.GilVendor;

    public static bool HasResolvedGilVendor(uint itemId)
    {
        EnsureVendorData();
        return VendorShopResolver.IsInitialized
            && VendorShopResolver.GilShopEntries.Any(entry => entry.ItemId == itemId && entry.Npcs.Count > 0);
    }

    public static IReadOnlyList<VulcanVendorStopHint> BuildVendorStops(IReadOnlyList<VulcanMaterialBlocker> blockers)
    {
        EnsureVendorData();
        if (!VendorShopResolver.IsInitialized)
            return Array.Empty<VulcanVendorStopHint>();

        var pending = blockers
            .Where(blocker => !blocker.Complete && IsGilVendorPreferred(blocker.ItemId))
            .GroupBy(blocker => blocker.ItemId)
            .Select(group => group.First())
            .ToDictionary(blocker => blocker.ItemId);
        if (pending.Count == 0)
            return Array.Empty<VulcanVendorStopHint>();

        var entriesByItem = VendorShopResolver.GilShopEntries
            .Where(entry => pending.ContainsKey(entry.ItemId) && entry.Npcs.Count > 0)
            .GroupBy(entry => entry.ItemId)
            .ToDictionary(group => group.Key, group => group.OrderBy(entry => entry.Cost).ToList());
        if (entriesByItem.Count == 0)
            return Array.Empty<VulcanVendorStopHint>();

        // Build NPC coverage first, then greedily pick the NPC that satisfies the
        // largest number of still-missing item types. This is a tiny set-cover problem;
        // greedy is deterministic, fast, and exactly what we want for crafting lists.
        var coverage = new Dictionary<uint, (VendorNpc Npc, HashSet<uint> ItemIds)>();
        foreach (var (itemId, entries) in entriesByItem)
        {
            foreach (var npc in entries.SelectMany(entry => entry.Npcs))
            {
                if (!coverage.TryGetValue(npc.NpcId, out var current))
                    current = (npc, new HashSet<uint>());
                current.ItemIds.Add(itemId);
                coverage[npc.NpcId] = current;
            }
        }

        var remaining = entriesByItem.Keys.ToHashSet();
        var stops = new List<VulcanVendorStopHint>();
        while (remaining.Count > 0)
        {
            var best = coverage.Values
                .Select(candidate => new
                {
                    candidate.Npc,
                    Items = candidate.ItemIds.Where(remaining.Contains).ToList(),
                    Location = VendorNpcLocationCache.TryGetFirstLocation(candidate.Npc.NpcId),
                })
                .Where(candidate => candidate.Items.Count > 0)
                .OrderByDescending(candidate => candidate.Items.Count)
                .ThenByDescending(candidate => candidate.Location != null)
                .ThenBy(candidate => candidate.Npc.Name, StringComparer.OrdinalIgnoreCase)
                .ThenBy(candidate => candidate.Npc.NpcId)
                .FirstOrDefault();

            if (best == null)
                break;

            var purchases = new List<VulcanVendorPurchaseHint>();
            foreach (var itemId in best.Items.OrderBy(itemId => pending[itemId].ItemName, StringComparer.OrdinalIgnoreCase))
            {
                var entry = entriesByItem[itemId]
                    .Where(candidate => candidate.Npcs.Any(npc => npc.NpcId == best.Npc.NpcId))
                    .OrderBy(candidate => candidate.Cost)
                    .FirstOrDefault();
                if (entry == null)
                    continue;

                var blocker = pending[itemId];
                purchases.Add(new VulcanVendorPurchaseHint(
                    itemId,
                    blocker.ItemName,
                    blocker.Missing,
                    entry.Cost,
                    string.IsNullOrWhiteSpace(entry.CurrencyName) ? "gil" : entry.CurrencyName));
                remaining.Remove(itemId);
            }

            if (purchases.Count == 0)
                break;

            var location = best.Location;
            var zoneName = location != null ? GetZoneName(location) : "Unknown location";
            float? mapX = null;
            float? mapY = null;
            if (location != null && TryGetMapCoordinates(location, out var coords))
            {
                mapX = coords.X;
                mapY = coords.Y;
            }

            stops.Add(new VulcanVendorStopHint(
                best.Npc.NpcId,
                best.Npc.Name,
                zoneName,
                mapX,
                mapY,
                purchases));
        }

        return stops;
    }

    public static string BuildVendorPlanSummary(IReadOnlyList<VulcanMaterialBlocker> blockers, int maxStops = 3)
    {
        var stops = BuildVendorStops(blockers);
        if (stops.Count == 0)
            return string.Empty;

        var summary = string.Join("; ", stops.Take(maxStops).Select(stop =>
            $"{stop.NpcName}: {string.Join(", ", stop.Purchases.Select(purchase => $"{purchase.ItemName} x{purchase.Missing}"))}"));
        if (stops.Count > maxStops)
            summary += $"; +{stops.Count - maxStops} more vendor stop(s)";
        return summary;
    }

    public static IReadOnlyList<string> GetVendorHintLines(VulcanMaterialBlocker blocker)
    {
        if (!IsGilVendorPreferred(blocker.ItemId))
            return Array.Empty<string>();

        var stops = BuildVendorStops(new[] { blocker });
        if (stops.Count == 0)
        {
            EnsureVendorData();
            return VendorShopResolver.IsInitialized
                ? new[] { "Gil vendor — vendor known, but no usable NPC/location was resolved." }
                : new[] { "Gil vendor — vendor/location data is still loading." };
        }

        var stop = stops[0];
        var purchase = stop.Purchases[0];
        var location = stop.MapX.HasValue && stop.MapY.HasValue
            ? $"{stop.ZoneName} (X {stop.MapX.Value:F1}, Y {stop.MapY.Value:F1})"
            : stop.ZoneName;
        var cost = purchase.Missing > 1
            ? $"{purchase.UnitCost:N0} {purchase.CurrencyName}/ea, {purchase.TotalCost:N0} total"
            : $"{purchase.UnitCost:N0} {purchase.CurrencyName}";
        return new[] { $"Buy from {stop.NpcName} — {location} — {cost}." };
    }

    private static void EnsureVendorData()
    {
        VendorShopResolver.InitializeAsync();
        if (VendorShopResolver.IsInitialized)
            VendorNpcLocationCache.InitializeAsync(VendorShopResolver.GetAllVendorNpcIds());
    }

    private static string GetZoneName(VendorNpcLocation location)
    {
        var territorySheet = Dalamud.GameData.GetExcelSheet<TerritoryType>();
        if (territorySheet == null || !territorySheet.TryGetRow(location.TerritoryId, out var territory))
            return $"Territory {location.TerritoryId}";

        return territory.PlaceName.RowId != 0
            ? territory.PlaceName.Value.Name.ToString()
            : $"Territory {location.TerritoryId}";
    }

    private static bool TryGetMapCoordinates(VendorNpcLocation location, out (float X, float Y) coords)
    {
        var mapSheet = Dalamud.GameData.GetExcelSheet<Map>();
        if (mapSheet == null || location.MapRowId == 0 || !mapSheet.TryGetRow(location.MapRowId, out var map) || map.SizeFactor == 0)
        {
            coords = default;
            return false;
        }

        const double factor = 0.019999999552965164d;
        var x = (float)((factor * map.OffsetX) + (2048.0d / map.SizeFactor) + (factor * location.Position.X) + 1.0d);
        var y = (float)((factor * map.OffsetY) + (2048.0d / map.SizeFactor) + (factor * location.Position.Z) + 1.0d);
        coords = (x, y);
        return x is >= 0f and <= 50f && y is >= 0f and <= 50f;
    }
}
