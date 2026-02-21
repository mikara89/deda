static class ValidateChecks
{
    public static void CheckStackServiceExists(string stack)
    {
        // This will throw if service doesn't exist
        DockerCli.Capture($"service inspect {stack}_deda --format \"{{{{.ID}}}}\"");
    }

    public static void CheckServiceOnManager(string stack)
    {
        // Ensure placement constraint includes node.role==manager
        var constraints = DockerCli.Capture($"service inspect {stack}_deda --format \"{{{{json .Spec.TaskTemplate.Placement.Constraints}}}}\"");
        if (!constraints.Contains("node.role == manager", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("DEDA service is not constrained to managers (node.role == manager).");
    }
}
