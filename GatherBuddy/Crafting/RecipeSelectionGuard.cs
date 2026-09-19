using System.Collections.Generic;
using System.Linq;
namespace GatherBuddy.Crafting;

public static class RecipeSelectionGuard
{
    public static bool Matches(uint requestedRecipe, uint requestedItem, uint selectedRecipe, uint selectedItem,
        IReadOnlyList<(uint itemId, int amount)> expected, IReadOnlyList<(uint itemId, int amount)> displayed)
        => requestedRecipe != 0 && requestedRecipe == selectedRecipe && requestedItem == selectedItem
           && (expected.Count == 0 || displayed.Count > 0)
           && displayed.All(ingredient => expected.Contains(ingredient));
}
