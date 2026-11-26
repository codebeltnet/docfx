namespace FrameworkFixture.Runtime;

/// <summary>
/// A shared widget. See <see cref="Companion"/>.
/// </summary>
/// <remarks>
/// Related APIs:
/// <a href="FrameworkFixture.Runtime.ModernFeature.html">modern feature link</a>,
/// <a href="FrameworkFixture.Runtime.StandardFeature.html">standard feature link</a>,
/// <a href="FrameworkFixture.Runtime.LegacyFeature.html">legacy feature link</a>,
/// <a href="../modern/FrameworkFixture.ModernApi.Endpoint.html?source=remarks#details">Modern Endpoint link</a>,
/// <a href="../standard/FrameworkFixture.StandardApi.Adapter.html?source=remarks#details">Standard Adapter link</a>,
/// <a href="FrameworkFixture.Runtime.MissingPage.html">missing page link</a>.
/// </remarks>
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

#if NETSTANDARD2_1 || NETSTANDARD2_0
/// <summary>An API documented only in .NET Standard views.</summary>
public class StandardFeature { }
#endif

#if NET48
/// <summary>An API documented in the .NET Framework view.</summary>
public class LegacyFeature { }
#endif
