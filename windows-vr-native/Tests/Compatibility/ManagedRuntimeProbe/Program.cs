using System.Reflection.Emit;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

// Reaching Main is itself a checkpoint: the game's earlier CoreCLR failure
// occurred before any managed entry point. No GC or W^X overrides are installed.
internal static class Program
{
    private sealed class Node
    {
        public object? Reference;
        public int Value;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void Assign(Node[] old, int generation)
    {
        for (int i = 0; i < old.Length; ++i)
            old[i].Reference = new Node { Value = generation * old.Length + i };
    }

    private static Func<int> Generate(int expected)
    {
        var method = new DynamicMethod("CompatibilityGeneratedCode", typeof(int), Type.EmptyTypes);
        var il = method.GetILGenerator();
        il.Emit(OpCodes.Ldc_I4, expected);
        il.Emit(OpCodes.Ret);
        return method.CreateDelegate<Func<int>>();
    }

    public static int Main()
    {
        using var journal = new StreamWriter(Path.Combine(AppContext.BaseDirectory, "managed-result.txt")) { AutoFlush = true };
        void Note(string text) { journal.WriteLine(text); Console.WriteLine(text); }
        try
        {
            Note($"START managed-runtime-v1 runtime={RuntimeInformation.FrameworkDescription} architecture={RuntimeInformation.ProcessArchitecture} run={Environment.GetEnvironmentVariable("WINEVISION_PROBE_RUN_ID") ?? "manual"}");
            Note($"CONFIG regionRange={Environment.GetEnvironmentVariable("DOTNET_GCRegionRange") ?? "default"} wx={Environment.GetEnvironmentVariable("DOTNET_EnableWriteXorExecute") ?? "default"}");
            // Godot's component loader reaches this through culture-aware
            // dictionary hashing before managed game initialization. Keep it
            // separate from the GC checkpoint to identify loader failures.
            Note("CHECK os-version begin");
            var version = Environment.OSVersion;
            if (version.Version.Major <= 0) throw new InvalidOperationException("Invalid OS version");
            Note($"CHECK os-version={version.Version} platform={version.Platform}");
            var names = new Dictionary<string, int>(StringComparer.CurrentCultureIgnoreCase) { ["Loader"] = 42 };
            if (names["loader"] != 42) throw new InvalidOperationException("Culture-aware dictionary failed");
            Note("CHECK culture-aware-loader-dictionary pass");
            var roots = Enumerable.Range(0, 2048).Select(i => new Node { Value = i }).ToArray();
            GC.Collect(2, GCCollectionMode.Forced, true, true);
            for (int iteration = 1; iteration <= 48; ++iteration)
            {
                Assign(roots, iteration);
                // Old-to-young stores exercise the write barrier before a Gen0 collection.
                GC.Collect(0, GCCollectionMode.Forced, true);
                for (int i = 0; i < roots.Length; ++i)
                    if (roots[i].Reference is not Node child || child.Value != iteration * roots.Length + i)
                        throw new InvalidOperationException($"Reference corruption at {iteration}:{i}");
                var generated = Generate(iteration);
                if (generated() != iteration) throw new InvalidOperationException("Generated code returned stale data");
                if (iteration % 8 == 0) GC.Collect(2, GCCollectionMode.Forced, true, true);
                Note($"CHECK iteration={iteration} generated={generated()} heapBytes={GC.GetTotalMemory(false)}");
            }
            GC.KeepAlive(roots);
            Note("RESULT PASS");
            return 0;
        }
        catch (Exception error)
        {
            Note($"RESULT FAIL {error}");
            return 1;
        }
    }
}
