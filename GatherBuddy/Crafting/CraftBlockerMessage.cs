using System;
namespace GatherBuddy.Crafting;

public static class CraftBlockerMessage
{
    public static string BuildAccess(string item, string job, int? level, int recipeLevel, string? missingQuest)
    {
        var reason = $"Recipe unavailable: {item}. You do not yet have access to this recipe. {job}: level {level?.ToString() ?? "unknown"}; recipe level {recipeLevel}.";
        if (!string.IsNullOrWhiteSpace(missingQuest))
            reason += $" Complete the required quest: {missingQuest}.";
        else if (level.HasValue && level.Value < recipeLevel)
            reason += " Your job level is below the recipe level. Level up and check that the recipe is available in your crafting log.";
        else
            reason += " Check the recipe unlock requirements in your crafting log.";
        return reason + " Unlock it, then press Resume.";
    }

    public static string BuildRepair(string job, int condition, int threshold)
        => $"Repair needed — {job}: equipment at {condition}%, threshold {threshold}%. Repair your gear, then press Resume. For automatic repairs, check your repair level, dark matter or access to a mender and sufficient gil.";

    public static string BuildMaterials(string recipe, string item, int needed, int nq, int hq)
        => nq + hq < needed
            ? $"Missing materials for {recipe}: {item} — need {needed}, in bags {nq} NQ + {hq} HQ. Obtain {Math.Max(0, needed - nq - hq)} more, then press Resume."
            : $"Cannot select the required material quality for {recipe}: {item} — in bags {nq} NQ + {hq} HQ. Check the NQ/HQ ingredient settings, then press Resume.";

    public static string Build(string item, string job, int level, int recipeLevel,
        int craftsmanship, int control, int cp, int requiredCraftsmanship, int requiredControl,
        bool intermediate, bool noSolution)
    {
        var reason = $"Crafting blocked: {item}. {job} level {level}, recipe level {recipeLevel}.";
        if (level == 0) reason += $" Unlock {job}.";
        if (craftsmanship < requiredCraftsmanship)
            reason += $" Craftsmanship: {craftsmanship}/{requiredCraftsmanship} (missing {requiredCraftsmanship - craftsmanship}).";
        if (control < requiredControl)
            reason += $" Control: {control}/{requiredControl} (missing {requiredControl - control}).";
        if (noSolution)
        {
            reason += $" No rotation found with {craftsmanship} craftsmanship, {control} control and {cp} CP.";
            if (level < recipeLevel && level > 0)
                reason += " Your job level is below the recipe level.";
        }
        reason += " Check your job, gear and crafting settings, then press Resume.";
        if (intermediate)
            reason += $" You can also obtain {item} manually in the required quantity and quality, then resume.";
        return reason;
    }
}
