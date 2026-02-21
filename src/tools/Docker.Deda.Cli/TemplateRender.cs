static class TemplateRender
{
    public static string Render(string template, Dictionary<string, string> vars)
    {
        var s = template;
        foreach (var kv in vars)
            s = s.Replace("${" + kv.Key + "}", kv.Value);
        return s;
    }
}
