using System.Diagnostics;

static class DockerCli
{
    public static void RequireDocker()
    {
        try { Run("version"); }
        catch { throw new InvalidOperationException("Docker CLI not available. Ensure 'docker' is on PATH and Docker is running."); }
    }

    public static void RequireSwarmActive()
    {
        var info = Capture("info --format \"{{.Swarm.LocalNodeState}}\"");
        if (!info.Trim().Equals("active", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Swarm not active (LocalNodeState={info.Trim()}). Run 'docker swarm init' or connect to a Swarm manager context.");
    }

    public static void Run(string args)
    {
        var psi = new ProcessStartInfo("docker", args)
        {
            RedirectStandardOutput = false,
            RedirectStandardError = false,
            UseShellExecute = false
        };
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start docker process.");
        p.WaitForExit();
        if (p.ExitCode != 0)
            throw new InvalidOperationException($"docker {args} failed with exit code {p.ExitCode}");
    }

    public static string Capture(string args)
    {
        var psi = new ProcessStartInfo("docker", args)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        };
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start docker process.");
        var stdout = p.StandardOutput.ReadToEnd();
        var stderr = p.StandardError.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0)
            throw new InvalidOperationException($"docker {args} failed: {stderr}");
        return stdout;
    }
}
