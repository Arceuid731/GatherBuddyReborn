using System;
using System.Collections.Generic;
using System.Linq;
using GatherBuddy.Vulcan.Vendors;
using Lumina.Excel.Sheets;

namespace GatherBuddy.Crafting;

public enum VulcanSupplyPreference
{
    GatherFirst,
    VendorFirst,
}

public sealed record VulcanVendorPurchaseHint(
    uint ItemId,
    string ItemName,
    int Missing,
    int RetainerAvailable,
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
/// Fork-local supply planner for crafting materials sold by gil vendors.
/// Vendor availability is treated as an alternative source, not an unconditional
/// override: users choose whether dual-source items should be gathered or bought.
/// Vendor-only materials still use the vendor regardless of that preference.
/// </summary>
public static class ForkVulcanSupplyPlan
{
    public static bool VendorDataLoading
        => !VendorShopResolver.IsInitialized && VendorShopResolver.IsInitializing;

    public static VulcanSupplyPreference Preference
        => GatherBuddy.Config.VulcanSupplyPreference;

    public static void SetPreference(VulcanSupplyPreference preference)
    {
        if (GatherBuddy.Config.VulcanSupplyPreference == preference)
            return;

        GatherBuddy.Config.VulcanSupplyPreference = preference;
        GatherBuddy.Config.Save();
        ForkVulcanWorkflowSupport.AddActivity(
            preference == VulcanSupplyPreference.GatherFirst
                ? "Supply preference changed: gather free materials first; vendor alternatives remain visible."
                : "Supply preference changed: buy gil-vendor materials first; gathering alternatives remain visible.",
            VulcanActivityKind.Info);
    }

    public static bool IsGilVendorAvailable(uint itemId)
        => MaterialSourceClassifier.Classify(itemId, preferVendors: true) == MaterialSource.GilVendor;

    public static bool HasDualSource(uint itemId)
        => IsGilVendorAvailable(itemId) && ForkVulcanWorkflowSupport.IsActuallyAutoGatherable(itemId);

    public static bool ShouldUseVendor(uint itemId)
        => IsGilVendorAvailable(itemId)
        && (Preference == VulcanSupplyPreference.VendorFirst
         || !ForkVulcanWorkflowSupport.IsActuallyAutoGatherable(itemId));

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
            .Where(blocker => !blocker.Complete && ShouldUseVendor(blocker.ItemId))
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

        // Greedy set-cover: on every stop pick the NPC covering the largest number of still-missing item types.
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
                    blocker.RetainerAvailable,
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
        if (!IsGilVendorAvailable(blocker.ItemId))
            return Array.Empty<string>();

        var hint = GetVendorAlternativeHint(blocker.ItemId, blocker.Missing);
        return string.IsNullOrWhiteSpace(hint) ? Array.Empty<string>() : new[] { $"Vendor: {hint}" };
    }

    public static string GetVendorAlternativeHint(uint itemId, int missing)
    {
        if (!IsGilVendorAvailable(itemId) || missing <= 0)
            return string.Empty;

        EnsureVendorData();
        if (!VendorShopResolver.IsInitialized)
            return "seller/location data is still loading.";

        var candidates = VendorShopResolver.GilShopEntries
            .Where(entry => entry.ItemId == itemId && entry.Npcs.Count > 0)
            .OrderBy(entry => entry.Cost)
            .ToList();
        if (candidates.Count == 0)
            return "vendor known, but no usable seller was resolved.";

        var best = candidates
            .SelectMany(entry => entry.Npcs.Select(npc => new
            {
                Entry = entry,
                Npc = npc,
                Location = VendorNpcLocationCache.TryGetFirstLocation(npc.NpcId),
            }))
            .OrderByDescending(candidate => candidate.Location != null)
            .ThenBy(candidate => candidate.Entry.Cost)
            .ThenBy(candidate => candidate.Npc.Name, StringComparer.OrdinalIgnoreCase)
            .First();

        var location = best.Location != null
            ? FormatLocation(best.Location)
            : "unknown location";
        var currency = string.IsNullOrWhiteSpace(best.Entry.CurrencyName) ? "gil" : best.Entry.CurrencyName;
        var total = (long)missing * best.Entry.Cost;
        var price = missing > 1
            ? $"{best.Entry.Cost:N0} {currency}/ea, {total:N0} total"
            : $"{best.Entry.Cost:N0} {currency}";
        return $"{best.Npc.Name} — {location} — {price}.";
    }

    public static string GetGatherAlternativeHint(uint itemId)
        => HasDualSource(itemId)
            ? "Gathering alternative available: this item has a real BTN/MIN/FSH source, so Gather first can obtain it without spending gil."
            : string.Empty;

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

    private static string FormatLocation(VendorNpcLocation location)
    {
        var zone = GetZoneName(location);
        return TryGetMapCoordinates(location, out var coords)
            ? $"{zone} (X {coords.X:F1}, Y {coords.Y:F1})"
            : zone;
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
