using System;
using System.Collections.Generic;
using System.Linq;

namespace GatherBuddy.Crafting;

public sealed record VulcanMobLocationHint(
    uint ItemId,
    uint BNpcNameId,
    string MobName,
    string ZoneName,
    uint TerritoryTypeId,
    uint MapRowId,
    float MapX,
    float MapY,
    int SpawnPointCount)
{
    public bool HasCoordinates
        => TerritoryTypeId != 0 && MapRowId != 0 && MapX > 0f && MapY > 0f;
}

/// <summary>
/// Live source view used by Crafting Status. This deliberately does not trust the
/// source value captured when a manual blocker was first built: supply preference
/// can change while the queue is paused and MobDropInfoCache initializes async.
/// </summary>
public static class ForkVulcanMobSources
{
    public static MaterialSource GetEffectiveSource(VulcanMaterialBlocker blocker)
    {
        if (ForkVulcanSupplyPlan.ShouldUseVendor(blocker.ItemId))
            return MaterialSource.GilVendor;

        if (ForkVulcanWorkflowSupport.IsActuallyAutoGatherable(blocker.ItemId))
            return ForkVulcanWorkflowSupport.ClassifyForAcquisition(blocker.ItemId);

        var dropInfo = MobDropInfoCache.GetDropInfoForItem(blocker.ItemId);
        if (dropInfo.HasData || MobDropInfoCache.IsKnownDropItem(blocker.ItemId))
            return MaterialSource.Drop;

        return ForkVulcanWorkflowSupport.ClassifyForAcquisition(blocker.ItemId);
    }

    public static IReadOnlyList<VulcanMobLocationHint> GetLocations(uint itemId, int maxLocations = 6)
    {
        var dropInfo = MobDropInfoCache.GetDropInfoForItem(itemId);
        if (!dropInfo.HasData)
            return Array.Empty<VulcanMobLocationHint>();

        return dropInfo.Mobs
            .SelectMany(mob => mob.Zones.SelectMany(zone =>
                zone.Clusters.Select(cluster => new VulcanMobLocationHint(
                    itemId,
                    mob.BNpcNameId,
                    string.IsNullOrWhiteSpace(mob.MobName) ? "Unknown monster" : mob.MobName,
                    zone.ZoneName,
                    cluster.TerritoryTypeId,
                    cluster.MapRowId,
                    cluster.MapX,
                    cluster.MapY,
                    cluster.SpawnPointCount))))
            .OrderByDescending(location => location.SpawnPointCount)
            .ThenBy(location => location.ZoneName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(location => location.MobName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(location => location.MapX)
            .ThenBy(location => location.MapY)
            .Take(Math.Max(1, maxLocations))
            .ToList();
    }
}
