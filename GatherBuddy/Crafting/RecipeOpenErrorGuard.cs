using System;
namespace GatherBuddy.Crafting;

public static class RecipeOpenErrorGuard
{
    public static bool ShouldCapture(uint? pendingRecipe, uint? currentRecipe, TimeSpan elapsed,
        bool preparing, bool correctRecipeVisible)
        => preparing && pendingRecipe.HasValue && pendingRecipe == currentRecipe
           && elapsed >= TimeSpan.Zero && elapsed <= TimeSpan.FromSeconds(2)
           && !correctRecipeVisible;
}
