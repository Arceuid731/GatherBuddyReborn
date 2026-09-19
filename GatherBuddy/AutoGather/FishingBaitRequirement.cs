using System;
using System.Linq;
using System.Text.Json;

namespace GatherBuddy.AutoGather;

internal static class FishingBaitRequirement
{
    // Read the selected preset, never an unrelated preset with a matching fish ID.
    public static uint Resolve(string json, string? expectedName, string? alternateName, bool global, uint equippedBait)
    {
        using var document = JsonDocument.Parse(json);
        if (!document.RootElement.TryGetProperty("HookPresets", out var presets)) return 0;
        var selectedId = presets.TryGetProperty("SelectedGuid", out var id) ? id.GetString() : null;
        JsonElement selected = default;
        if (global)
        {
            if (!string.IsNullOrEmpty(selectedId) && selectedId != Guid.Empty.ToString()) return 0;
            if (!presets.TryGetProperty("DefaultPreset", out selected)) return 0;
        }
        else
        {
            if (string.IsNullOrEmpty(expectedName) || !presets.TryGetProperty("CustomPresets", out var custom)) return 0;
            selected = custom.EnumerateArray().FirstOrDefault(p =>
                p.TryGetProperty("UniqueId", out var key) && key.GetString() == selectedId);
            if (selected.ValueKind != JsonValueKind.Object || !selected.TryGetProperty("PresetName", out var name)) return 0;
            if (name.GetString() != expectedName && name.GetString() != alternateName) return 0;
        }
        if (selected.TryGetProperty("ExtraCfg", out var extra) && extra.ValueKind == JsonValueKind.Object
            && extra.TryGetProperty("Enabled", out var enabled) && enabled.ValueKind == JsonValueKind.True
            && extra.TryGetProperty("ForceBaitSwap", out var force) && force.ValueKind == JsonValueKind.True
            && extra.TryGetProperty("ForcedBaitId", out var bait) && bait.TryGetUInt32(out var baitId) && baitId != 0)
            return baitId;
        return equippedBait;
    }
}
