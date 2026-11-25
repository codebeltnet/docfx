namespace FrameworkFixture.Runtime;

/// <summary>
/// A shared widget. See <see cref="Companion"/>.
/// </summary>
public class Widget
{
    /// <summary>Resets the widget.</summary>
    public void Reset() { }

#if NET11_0 || NET10_0 || NETSTANDARD2_1
    /// <summary>Resets a numbered widget.</summary>
    public void Reset(int number) { }
#endif
}

/// <summary>A companion for the widget.</summary>
public class Companion { }

#if NET11_0 || NET10_0
/// <summary>An API documented in two newer views.</summary>
public class ModernFeature { }
#endif

#if NET48
/// <summary>An API documented in the .NET Framework view.</summary>
public class LegacyFeature { }
#endif
