namespace GatherBuddy.Crafting;

// Keep solver diagnostics out of player-facing messages. A recipe's displayed
// level is not treated as a hard crafting requirement.
public static class CraftBlockerMessage
{
    public static string Build(bool french, string item, string job, int level, int recipeLevel,
        int craftsmanship, int control, int cp, int requiredCraftsmanship, int requiredControl,
        bool intermediate, bool noSolution)
    {
        var reason = french
            ? $"Fabrication bloquée : {item}. {job} niv. {level}, recette niv. {recipeLevel}."
            : $"Crafting blocked: {item}. {job} level {level}, recipe level {recipeLevel}.";
        if (level == 0)
            reason += french ? $" Débloquez le métier {job}." : $" Unlock {job}.";
        if (craftsmanship < requiredCraftsmanship)
            reason += french
                ? $" Habileté : {craftsmanship}/{requiredCraftsmanship} (manque {requiredCraftsmanship - craftsmanship})."
                : $" Craftsmanship: {craftsmanship}/{requiredCraftsmanship} (missing {requiredCraftsmanship - craftsmanship}).";
        if (control < requiredControl)
            reason += french
                ? $" Contrôle : {control}/{requiredControl} (manque {requiredControl - control})."
                : $" Control: {control}/{requiredControl} (missing {requiredControl - control}).";
        if (noSolution)
        {
            reason += french
                ? $" Aucune rotation trouvée avec {craftsmanship} d’habileté, {control} de contrôle et {cp} PS."
                : $" No rotation found with {craftsmanship} craftsmanship, {control} control and {cp} CP.";
            if (level < recipeLevel && level > 0)
                reason += french ? " Le niveau du métier est inférieur à celui de la recette." : " Your job level is below the recipe level.";
        }
        reason += french
            ? " Vérifiez votre métier, votre équipement et vos réglages de fabrication, puis cliquez sur Reprendre."
            : " Check your job, gear and crafting settings, then press Resume.";
        if (intermediate)
            reason += french
                ? $" Vous pouvez aussi obtenir {item} manuellement, dans la quantité et la qualité nécessaires, puis reprendre."
                : $" You can also obtain {item} manually in the required quantity and quality, then resume.";
        return reason;
    }
}
