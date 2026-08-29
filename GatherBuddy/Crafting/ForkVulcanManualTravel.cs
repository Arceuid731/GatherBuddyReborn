using System;
using System.Numerics;
using GatherBuddy.Vulcan.Vendors;
using Lumina.Excel.Sheets;

namespace GatherBuddy.Crafting;

/// <summary>
/// Optional travel assistance for Vulcan steps that intentionally remain manual.
/// It reuses VendorNavigator's mature teleport/aethernet/vnavmesh routing, but never
/// completes or resumes the crafting queue. Arrival only puts the player at the
/// requested source; inventory acquisition and Resume stay explicitly user-driven.
/// </summary>
public static class ForkVulcanManualTravel
{
    private static readonly VendorNavigator Navigator = new();

    private static bool _active;
    private static string _destinationLabel = string.Empty;
    private static string _statusText = string.Empty;
    private static int _missingQuantity;

    public static bool IsActive => _active;
    public static string StatusText => _statusText;

    public static bool StartMobTravel(VulcanMobLocationHint location, int missingQuantity)
    {
        if (!location.HasCoordinates)
            return false;

        if (!TryMapToWorldPosition(
                location.TerritoryTypeId,
                location.MapRowId,
                location.MapX,
                location.MapY,
                out var worldPosition))
        {
            ForkVulcanWorkflowSupport.AddActivity(
                $"Could not resolve navigation coordinates for {location.MobName} in {location.ZoneName}.",
                VulcanActivityKind.Error);
            return false;
        }

        var target = new VendorNpcLocation(
            0u,
            $"{location.MobName} spawn",
            location.TerritoryTypeId,
            location.MapRowId,
            worldPosition,
            VendorNpcLocationSource.Override);

        _destinationLabel = $"{location.MobName} — {location.ZoneName} (X {location.MapX:F1}, Y {location.MapY:F1})";
        _missingQuantity = Math.Max(0, missingQuantity);
        Start(target, $"Travelling to {_destinationLabel}...");
        ForkVulcanWorkflowSupport.AddActivity(
            $"Go: travelling to {_destinationLabel}. Vulcan will stay paused for manual farming.",
            VulcanActivityKind.Info);
        return true;
    }

    public static bool StartVendorTravel(VulcanVendorStopHint stop)
    {
        var location = VendorNpcLocationCache.TryGetFirstLocation(stop.NpcId);
        if (location == null)
        {
            ForkVulcanWorkflowSupport.AddActivity(
                $"Could not resolve a navigation location for vendor {stop.NpcName}.",
                VulcanActivityKind.Error);
            return false;
        }

        _destinationLabel = stop.MapX.HasValue && stop.MapY.HasValue
            ? $"{stop.NpcName} — {stop.ZoneName} (X {stop.MapX.Value:F1}, Y {stop.MapY.Value:F1})"
            : $"{stop.NpcName} — {stop.ZoneName}";
        _missingQuantity = 0;
        Start(location, $"Travelling to {_destinationLabel}...");
        ForkVulcanWorkflowSupport.AddActivity(
            $"Go: travelling to vendor {_destinationLabel}. Vulcan will stay paused for manual purchasing.",
            VulcanActivityKind.Info);
        return true;
    }

    public static void Update()
    {
        if (!_active)
            return;

        Navigator.Update();
        if (Navigator.IsReadyToPurchase)
        {
            Navigator.Stop();
            _active = false;
            _statusText = _missingQuantity > 0
                ? $"Arrived: {_destinationLabel}. Farm as many as you want (currently need {_missingQuantity}), then press Resume when ready."
                : $"Arrived: {_destinationLabel}. Buy what you need, then press Resume when ready.";
            ForkVulcanWorkflowSupport.AddActivity(_statusText, VulcanActivityKind.Success);
        }
        else if (Navigator.IsFailed)
        {
            Navigator.Stop();
            _active = false;
            _statusText = $"Travel failed: {_destinationLabel}. Use the displayed map coordinates manually or try Go again.";
            ForkVulcanWorkflowSupport.AddActivity(_statusText, VulcanActivityKind.Error);
        }
    }

    public static void Stop(bool clearStatus = false)
    {
        Navigator.Stop();
        _active = false;
        _destinationLabel = string.Empty;
        _missingQuantity = 0;
        if (clearStatus)
            _statusText = string.Empty;
    }

    private static void Start(VendorNpcLocation target, string status)
    {
        Navigator.Stop();
        _active = true;
        _statusText = status;
        Navigator.StartNavigation(target);
    }

    private static bool TryMapToWorldPosition(
        uint territoryTypeId,
        uint mapRowId,
        float mapX,
        float mapY,
        out Vector3 position)
    {
        position = default;
        if (territoryTypeId == 0 || mapRowId == 0 || mapX <= 0f || mapY <= 0f)
            return false;

        var mapSheet = Dalamud.GameData.GetExcelSheet<Map>();
        if (mapSheet == null || !mapSheet.TryGetRow(mapRowId, out var map) || map.SizeFactor == 0)
            return false;

        const double factor = 0.019999999552965164d;
        var worldX = (mapX - 1.0d - (2048.0d / map.SizeFactor) - (factor * map.OffsetX)) / factor;
        var worldZ = (mapY - 1.0d - (2048.0d / map.SizeFactor) - (factor * map.OffsetY)) / factor;

        // VendorNavigator snaps cached positions back onto vnavmesh before pathing,
        // so an exact world Y is unnecessary. Reuse the player's Y when already in
        // the territory to give the snap an even better seed.
        var worldY = Dalamud.ClientState.TerritoryType == territoryTypeId
            ? Dalamud.Objects.LocalPlayer?.Position.Y ?? 0f
            : 0f;

        position = new Vector3((float)worldX, worldY, (float)worldZ);
        return float.IsFinite(position.X) && float.IsFinite(position.Z);
    }
}
