using System;
using Dalamud.Game.ClientState.Conditions;
using FFXIVClientStructs.FFXIV.Client.Game.UI;
using GatherBuddy.Plugin;

namespace GatherBuddy.Helpers;

public static class HomeNavigationHelper
{
    public static bool ShouldReturnHomeAfterCollectables()
        => GatherBuddy.Config.AutoGatherConfig.GoHomeWhenIdle;

    /// <summary>
    /// Crafting automation may safely remain where it is when the game reports the
    /// player is inside a sanctuary. This is the same game-side sanctuary signal
    /// used by Lifestream when deciding whether it needs to move before travel.
    /// </summary>
    public static unsafe bool IsInSafeCraftingArea()
    {
        var territoryInfo = TerritoryInfo.Instance();
        return territoryInfo != null && territoryInfo->InSanctuary;
    }

    public static bool TryStartReturnHome(out string? error)
    {
        error = null;
        if (Dalamud.Conditions[ConditionFlag.BoundByDuty])
        {
            error = "Cannot return home while bound by duty.";
            return false;
        }

        if (!Lifestream.Enabled)
        {
            error = "Lifestream is not available.";
            return false;
        }

        if (Lifestream.IsBusy())
            return false;

        var command = GatherBuddy.Config.AutoGatherConfig.LifestreamCommand;
        if (string.IsNullOrWhiteSpace(command))
            command = "auto";
        if (command.Contains("/li ", StringComparison.OrdinalIgnoreCase))
            command = command.Replace("/li ", string.Empty, StringComparison.OrdinalIgnoreCase);

        Lifestream.ExecuteCommand(command);
        return true;
    }

    public static bool IsReturnComplete()
        => !Lifestream.Enabled || !Lifestream.IsBusy();
}
