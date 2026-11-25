#:property TargetFramework=net10.0
#:property Nullable=enable
#:property PublishAot=false

using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.Formats.Tar;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Codebelt.Docfx;

internal static class OciArtifact
{
    private const string OciIndexMediaType = "application/vnd.oci.image.index.v1+json";
    private const string DefaultSourceUrl = "https://github.com/codebeltnet/docfx";
    private const string SpdxPredicateType = "https://spdx.dev/Document";
    private const string SlsaPredicatePrefix = "https://slsa.dev/provenance/";
    private const long DefaultPartSizeBytes = 1024L * 1024L * 1024L; // 1 GiB
    private const long MaxCachedJsonBytes = 32L * 1024L * 1024L;

    private static readonly UTF8Encoding Utf8NoBom = new(false);
    private static readonly Regex Sha256HexPattern = new(@"^[0-9a-f]{64}$", RegexOptions.CultureInvariant);
    private static readonly Regex Sha256AnyCasePattern = new(@"^[0-9a-fA-F]{64}$", RegexOptions.CultureInvariant);
    private static readonly Regex CommitShaPattern = new(@"^[0-9a-f]{40}$", RegexOptions.CultureInvariant);
    private static readonly Regex PartNamePattern = new(@"^[A-Za-z0-9_.-]+\.oci\.part\d{3}$", RegexOptions.CultureInvariant);

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0)
            {
                throw new InvalidDataException("Expected a command: verify, merge, loaded-config, seal, check-seal, split, reassemble, or extract-layout.");
            }

            var command = args[0];
            var rest = args[1..];

            switch (command)
            {
                case "verify":
                    RunVerify(rest);
                    break;
                case "merge":
                    RunMerge(rest);
                    break;
                case "loaded-config":
                    RunLoadedConfig(rest);
                    break;
                case "seal":
                    RunSeal(rest);
                    break;
                case "check-seal":
                    RunCheckSeal(rest);
                    break;
                case "split":
                    RunSplit(rest);
                    break;
                case "reassemble":
                    RunReassemble(rest);
                    break;
                case "extract-layout":
                    RunExtractLayout(rest);
                    break;
                default:
                    throw new InvalidDataException($"Unknown command '{command}'.");
            }

            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }

    private static void Require([DoesNotReturnIf(false)] bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidDataException(message);
        }
    }

    private static (List<string> Positionals, Dictionary<string, List<string>> Options) ParseArgs(string[] args, HashSet<string>? flagOptions = null)
    {
        var positionals = new List<string>();
        var options = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        flagOptions ??= new HashSet<string>(StringComparer.Ordinal);

        for (var i = 0; i < args.Length; i++)
        {
            var token = args[i];
            if (token.StartsWith("--", StringComparison.Ordinal))
            {
                if (flagOptions.Contains(token))
                {
                    if (!options.TryGetValue(token, out var flags))
                    {
                        flags = new List<string>();
                        options[token] = flags;
                    }
                    flags.Add("true");
                }
                else
                {
                    Require(i + 1 < args.Length, $"Missing value for option '{token}'.");
                    var value = args[++i];
                    if (!options.TryGetValue(token, out var list))
                    {
                        list = new List<string>();
                        options[token] = list;
                    }
                    list.Add(value);
                }
            }
            else
            {
                positionals.Add(token);
            }
        }

        return (positionals, options);
    }

    private static string? GetOption(Dictionary<string, List<string>> options, string name)
        => options.TryGetValue(name, out var values) && values.Count > 0 ? values[^1] : null;

    private static string GetRequiredOption(Dictionary<string, List<string>> options, string name)
    {
        var value = GetOption(options, name);
        Require(!string.IsNullOrWhiteSpace(value), $"Option '{name}' is required.");
        return value!;
    }

    private static bool HasFlag(Dictionary<string, List<string>> options, string name)
        => options.ContainsKey(name);

    private static string ComputeFileSha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static string ComputeBytesSha256(byte[] bytes)
        => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static void WriteSeal(string archivePath, string? checksumPath = null)
    {
        var fullArchive = Path.GetFullPath(archivePath);
        Require(File.Exists(fullArchive) && new FileInfo(fullArchive).Length > 0, $"OCI archive is missing or empty: {fullArchive}");
        var target = checksumPath is null ? fullArchive + ".sha256" : Path.GetFullPath(checksumPath);
        var digest = ComputeFileSha256(fullArchive);
        var fileName = Path.GetFileName(fullArchive);
        File.WriteAllText(target, $"{digest}  {fileName}\n", Utf8NoBom);
    }

    private static string CheckSeal(string archivePath, string? checksumPath = null)
    {
        var fullArchive = Path.GetFullPath(archivePath);
        var fullChecksum = checksumPath is null ? fullArchive + ".sha256" : Path.GetFullPath(checksumPath);
        Require(File.Exists(fullArchive) && new FileInfo(fullArchive).Length > 0, $"OCI archive is missing or empty: {fullArchive}");
        Require(File.Exists(fullChecksum), $"OCI archive checksum is missing: {fullChecksum}");

        var line = File.ReadAllText(fullChecksum, Encoding.UTF8).Trim();
        var fields = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        Require(fields.Length == 2 && Sha256AnyCasePattern.IsMatch(fields[0]),
            "The checksum file must contain one GNU-style SHA-256 checksum record.");

        var recordedName = fields[1].TrimStart('*');
        Require(string.Equals(Path.GetFileName(recordedName), Path.GetFileName(fullArchive), StringComparison.Ordinal),
            $"The checksum file names '{recordedName}', expected '{Path.GetFileName(fullArchive)}'.");

        var actual = ComputeFileSha256(fullArchive);
        Require(string.Equals(actual, fields[0], StringComparison.OrdinalIgnoreCase),
            $"Archive checksum mismatch: expected {fields[0].ToLowerInvariant()}, found {actual}.");
        return actual;
    }

    private static void RunSeal(string[] args)
    {
        var (positionals, options) = ParseArgs(args);
        Require(positionals.Count == 1, "Expected archive path.");
        var archive = Path.GetFullPath(positionals[0]);
        var checksumPath = GetOption(options, "--checksum");
        WriteSeal(archive, checksumPath);
        var digest = ComputeFileSha256(archive);
        Console.WriteLine(JsonSerializer.Serialize(new { archiveSha256 = digest }));
    }

    private static void RunCheckSeal(string[] args)
    {
        var (positionals, options) = ParseArgs(args);
        Require(positionals.Count == 1, "Expected archive path.");
        var archive = Path.GetFullPath(positionals[0]);
        var checksumPath = GetOption(options, "--checksum");
        var digest = CheckSeal(archive, checksumPath);
        Console.WriteLine(JsonSerializer.Serialize(new { archiveSha256 = digest }));
    }

    private static VerificationIdentity ReadIdentity(Dictionary<string, List<string>> options)
    {
        var version = GetRequiredOption(options, "--version");
        var docfxVersion = GetRequiredOption(options, "--docfx-version");
        var revision = GetRequiredOption(options, "--revision");
        var source = GetOption(options, "--source") ?? DefaultSourceUrl;
        var platform = GetOption(options, "--platform");

        Require(CommitShaPattern.IsMatch(revision), "The source revision must be a lowercase 40-character commit SHA.");
        if (platform is not null)
        {
            Require(platform is "amd64" or "arm64", $"Unsupported platform '{platform}'. Expected 'amd64' or 'arm64'.");
        }

        return new VerificationIdentity(version, docfxVersion, revision, source, platform);
    }

    private static void RunVerify(string[] args)
    {
        var (positionals, options) = ParseArgs(args, new HashSet<string>(StringComparer.Ordinal) { "--no-seal", "--check-seal" });
        Require(positionals.Count == 1, "Expected archive path.");
        var archivePath = Path.GetFullPath(positionals[0]);
        var identity = ReadIdentity(options);
        var expectedDigest = GetOption(options, "--expected-digest");

        if (HasFlag(options, "--check-seal"))
        {
            CheckSeal(archivePath);
        }

        var archive = OciArchive.Open(archivePath);
        var expectedPlatforms = identity.Platform is not null
            ? new[] { identity.Platform }
            : new[] { "amd64", "arm64" };

        var result = archive.Verify(identity, expectedPlatforms, expectedDigest);

        if (!HasFlag(options, "--no-seal"))
        {
            WriteSeal(archivePath);
        }

        var archiveSha256 = ComputeFileSha256(archivePath);
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            indexDigest = result.IndexDigest,
            archiveSha256,
            platforms = result.Platforms,
            configs = result.Configs
        }));
    }

    private static void RunMerge(string[] args)
    {
        var (positionals, options) = ParseArgs(args, new HashSet<string>(StringComparer.Ordinal) { "--no-input-seal" });
        Require(positionals.Count == 1, "Expected output archive path.");
        var outputPath = Path.GetFullPath(positionals[0]);
        var identity = ReadIdentity(options);
        Require(options.TryGetValue("--input", out var inputPaths) && inputPaths.Count > 0, "At least one --input archive is required.");

        var checkInputSeal = !HasFlag(options, "--no-input-seal");
        var expectedPlatforms = identity.Platform is not null
            ? new[] { identity.Platform }
            : new[] { "amd64", "arm64" };

        var inputs = new List<(string Path, OciArchive Archive, string Architecture)>();
        var mergedManifests = new JsonArray();
        var seenArchitectures = new HashSet<string>(StringComparer.Ordinal);

        foreach (var rawInput in inputPaths)
        {
            var fullInput = Path.GetFullPath(rawInput);
            if (checkInputSeal)
            {
                CheckSeal(fullInput);
            }

            var archive = OciArchive.Open(fullInput);
            var runnableArchs = archive.GetRunnableArchitectures();
            Require(runnableArchs.Count == 1, $"Expected one tested platform per input archive, found {runnableArchs.Count} in '{fullInput}'.");
            var arch = runnableArchs[0];
            Require(seenArchitectures.Add(arch), $"Duplicate input platform '{arch}'.");

            archive.Verify(identity, new[] { arch }, null);

            foreach (var manifest in archive.IndexElement.GetProperty("manifests").EnumerateArray())
            {
                mergedManifests.Add(JsonNode.Parse(manifest.GetRawText()));
            }

            inputs.Add((fullInput, archive, arch));
        }

        var missing = expectedPlatforms.Where(p => !seenArchitectures.Contains(p)).ToArray();
        Require(missing.Length == 0 && seenArchitectures.Count == expectedPlatforms.Length,
            $"Unexpected platform inventory for merge: [{string.Join(", ", seenArchitectures.Order(StringComparer.Ordinal))}].");

        var embeddedIndexNode = new JsonObject
        {
            ["schemaVersion"] = 2,
            ["mediaType"] = OciIndexMediaType,
            ["manifests"] = mergedManifests,
            ["annotations"] = new JsonObject
            {
                ["org.opencontainers.image.version"] = identity.Version,
                ["org.opencontainers.image.revision"] = identity.Revision,
                ["net.codebelt.docfx.engine.version"] = identity.Version,
                ["net.codebelt.docfx.cli.version"] = identity.DocfxVersion
            }
        };

        var embeddedIndexBytes = Encoding.UTF8.GetBytes(embeddedIndexNode.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
        var embeddedIndexHex = ComputeBytesSha256(embeddedIndexBytes);
        var embeddedIndexDigest = "sha256:" + embeddedIndexHex;

        var layoutIndexNode = new JsonObject
        {
            ["schemaVersion"] = 2,
            ["mediaType"] = OciIndexMediaType,
            ["manifests"] = new JsonArray
            {
                new JsonObject
                {
                    ["mediaType"] = OciIndexMediaType,
                    ["digest"] = embeddedIndexDigest,
                    ["size"] = embeddedIndexBytes.LongLength,
                    ["annotations"] = new JsonObject
                    {
                        ["org.opencontainers.image.ref.name"] = identity.Version
                    }
                }
            }
        };

        var layoutIndexBytes = Encoding.UTF8.GetBytes(layoutIndexNode.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
        var ociLayoutBytes = Encoding.UTF8.GetBytes("{\"imageLayoutVersion\":\"1.0.0\"}");

        var outputDir = Path.GetDirectoryName(outputPath);
        if (!string.IsNullOrEmpty(outputDir))
        {
            Directory.CreateDirectory(outputDir);
        }

        var seenBlobs = new HashSet<string>(StringComparer.Ordinal);
        using (var outputStream = File.Create(outputPath))
        using (var writer = new TarWriter(outputStream, TarEntryFormat.Pax, leaveOpen: false))
        {
            foreach (var input in inputs)
            {
                using var inputStream = File.OpenRead(input.Path);
                using var reader = new TarReader(inputStream, leaveOpen: false);
                TarEntry? entry;
                while ((entry = reader.GetNextEntry(copyData: false)) is not null)
                {
                    if (entry.EntryType == TarEntryType.Directory)
                    {
                        continue;
                    }

                    var normalized = NormalizeMemberName(entry.Name);
                    if (!normalized.StartsWith("blobs/sha256/", StringComparison.Ordinal))
                    {
                        continue;
                    }

                    if (!seenBlobs.Add(normalized))
                    {
                        continue;
                    }

                    Require(entry.DataStream is not null, $"OCI archive entry '{normalized}' has no data.");
                    var outEntry = new PaxTarEntry(TarEntryType.RegularFile, normalized)
                    {
                        DataStream = entry.DataStream
                    };
                    writer.WriteEntry(outEntry);
                }
            }

            if (seenBlobs.Add("blobs/sha256/" + embeddedIndexHex))
            {
                WriteBytesEntry(writer, "blobs/sha256/" + embeddedIndexHex, embeddedIndexBytes);
            }
            WriteBytesEntry(writer, "index.json", layoutIndexBytes);
            WriteBytesEntry(writer, "oci-layout", ociLayoutBytes);
        }

        // Re-verify the assembled multi-platform archive end-to-end before sealing.
        var verified = OciArchive.Open(outputPath).Verify(identity, expectedPlatforms, embeddedIndexDigest);
        WriteSeal(outputPath);
        var archiveSha256 = ComputeFileSha256(outputPath);
        var archiveBytes = new FileInfo(outputPath).Length;

        Console.WriteLine(JsonSerializer.Serialize(new
        {
            indexDigest = verified.IndexDigest,
            archiveSha256,
            archiveBytes,
            platforms = verified.Platforms,
            configs = verified.Configs
        }));
    }

    private static void RunLoadedConfig(string[] args)
    {
        var (positionals, options) = ParseArgs(args);
        Require(positionals.Count == 1, "Expected archive path.");
        var archivePath = Path.GetFullPath(positionals[0]);
        var platform = GetRequiredOption(options, "--platform");
        var image = GetRequiredOption(options, "--image");
        var context = GetOption(options, "--context");

        Require(platform is "amd64" or "arm64", $"Unsupported platform '{platform}'.");

        var archive = OciArchive.Open(archivePath);
        var expectedConfigDigest = archive.GetPlatformConfigDigest(platform);
        var expectedHex = expectedConfigDigest["sha256:".Length..];

        var psi = new ProcessStartInfo("docker")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        };
        if (!string.IsNullOrWhiteSpace(context))
        {
            psi.ArgumentList.Add("--context");
            psi.ArgumentList.Add(context);
        }
        psi.ArgumentList.Add("image");
        psi.ArgumentList.Add("save");
        psi.ArgumentList.Add(image);

        using var process = Process.Start(psi) ?? throw new InvalidOperationException("Unable to start docker image save.");
        var stderrTask = process.StandardError.ReadToEndAsync();
        var found = false;

        try
        {
            using var reader = new TarReader(process.StandardOutput.BaseStream, leaveOpen: false);
            TarEntry? entry;
            while ((entry = reader.GetNextEntry(copyData: false)) is not null)
            {
                if (entry.EntryType is not (TarEntryType.RegularFile or TarEntryType.V7RegularFile))
                {
                    continue;
                }

                var normalized = entry.Name.StartsWith("./", StringComparison.Ordinal) ? entry.Name[2..] : entry.Name;
                if (string.Equals(normalized, "blobs/sha256/" + expectedHex, StringComparison.Ordinal)
                    || string.Equals(normalized, expectedHex + ".json", StringComparison.Ordinal))
                {
                    Require(entry.DataStream is not null, "Saved Docker config entry has no data.");
                    var actualHex = Convert.ToHexString(SHA256.HashData(entry.DataStream)).ToLowerInvariant();
                    Require(string.Equals("sha256:" + actualHex, expectedConfigDigest, StringComparison.Ordinal),
                        "Loaded config bytes changed.");
                    found = true;
                }
            }
        }
        finally
        {
            if (!process.HasExited)
            {
                process.WaitForExit();
            }
        }

        var stderr = stderrTask.GetAwaiter().GetResult().Trim();
        Require(process.ExitCode == 0 && found,
            $"Loaded config differs from exported OCI artifact{(string.IsNullOrEmpty(stderr) ? string.Empty : ": " + stderr)}.");

        Console.WriteLine(expectedConfigDigest);
    }

    private static void RunSplit(string[] args)
    {
        var (positionals, options) = ParseArgs(args, new HashSet<string>(StringComparer.Ordinal) { "--write-checksum" });
        Require(positionals.Count == 1, "Expected archive path.");
        var archivePath = Path.GetFullPath(positionals[0]);
        var outputDir = Path.GetFullPath(GetRequiredOption(options, "--output-dir"));
        var prefix = GetRequiredOption(options, "--prefix");
        var partSizeOption = GetOption(options, "--part-size");
        var partSize = partSizeOption is null ? DefaultPartSizeBytes : long.Parse(partSizeOption);

        Require(File.Exists(archivePath) && new FileInfo(archivePath).Length > 0, $"OCI archive is missing or empty: {archivePath}");
        Require(partSize > 0, "Part size must be a positive integer.");
        Require(Regex.IsMatch(prefix, @"^[A-Za-z0-9_.-]+$", RegexOptions.CultureInvariant), $"Invalid asset prefix '{prefix}'.");

        Directory.CreateDirectory(outputDir);

        var pieces = new List<object>();
        using var fullHasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[1024 * 1024];
        long totalBytes = 0;

        using (var source = File.OpenRead(archivePath))
        {
            var partIndex = 0;
            while (true)
            {
                var read = source.Read(buffer, 0, (int)Math.Min(buffer.Length, partSize));
                if (read == 0)
                {
                    break;
                }

                var partName = $"{prefix}.oci.part{partIndex:D3}";
                var partPath = Path.Combine(outputDir, partName);
                long partBytes = 0;
                using var partHasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);

                using (var target = File.Create(partPath))
                {
                    while (read > 0)
                    {
                        target.Write(buffer, 0, read);
                        partHasher.AppendData(buffer, 0, read);
                        fullHasher.AppendData(buffer, 0, read);
                        partBytes += read;
                        totalBytes += read;

                        var remaining = partSize - partBytes;
                        if (remaining <= 0)
                        {
                            break;
                        }

                        read = source.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
                    }
                }

                pieces.Add(new
                {
                    name = partName,
                    sha256 = Convert.ToHexString(partHasher.GetHashAndReset()).ToLowerInvariant(),
                    size = partBytes
                });
                partIndex++;
            }
        }

        var archiveSha256 = Convert.ToHexString(fullHasher.GetHashAndReset()).ToLowerInvariant();
        if (HasFlag(options, "--write-checksum"))
        {
            var checksumFile = Path.Combine(outputDir, Path.GetFileName(archivePath) + ".sha256");
            File.WriteAllText(checksumFile, $"{archiveSha256}  {Path.GetFileName(archivePath)}\n", Utf8NoBom);
        }

        Console.WriteLine(JsonSerializer.Serialize(new
        {
            archiveSha256,
            archiveBytes = totalBytes,
            pieces
        }));
    }

    private static void RunReassemble(string[] args)
    {
        var (_, options) = ParseArgs(args);
        var manifestPath = Path.GetFullPath(GetRequiredOption(options, "--manifest"));
        var inputDir = Path.GetFullPath(GetRequiredOption(options, "--input-dir"));
        var outputPath = Path.GetFullPath(GetRequiredOption(options, "--output"));
        var checksumPath = GetOption(options, "--checksum");

        Require(File.Exists(manifestPath), $"Release manifest is missing: {manifestPath}");
        using var document = JsonDocument.Parse(File.ReadAllText(manifestPath, Encoding.UTF8));
        var root = document.RootElement;

        var expectedArchiveSha = ReadStringCaseInsensitive(root, "ArchiveSha256");
        Require(!string.IsNullOrEmpty(expectedArchiveSha) && Sha256HexPattern.IsMatch(expectedArchiveSha),
            "Release manifest does not contain a valid ArchiveSha256.");

        var expectedArchiveBytes = ReadInt64CaseInsensitive(root, "ArchiveBytes");
        var piecesElement = GetPropertyCaseInsensitive(root, "Pieces");
        Require(piecesElement.ValueKind == JsonValueKind.Array && piecesElement.GetArrayLength() > 0,
            "Release manifest must contain at least one archive piece.");

        var outputDir = Path.GetDirectoryName(outputPath);
        if (!string.IsNullOrEmpty(outputDir))
        {
            Directory.CreateDirectory(outputDir);
        }

        using var fullHasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[1024 * 1024];
        long totalBytes = 0;

        using (var output = File.Create(outputPath))
        {
            foreach (var piece in piecesElement.EnumerateArray())
            {
                var name = ReadStringCaseInsensitive(piece, "Name");
                var expectedPieceSha = ReadStringCaseInsensitive(piece, "Sha256");
                var expectedPieceSize = ReadInt64CaseInsensitive(piece, "Size");

                Require(!string.IsNullOrEmpty(name) && PartNamePattern.IsMatch(name), $"Invalid piece identity '{name}'.");
                Require(!string.IsNullOrEmpty(expectedPieceSha) && Sha256HexPattern.IsMatch(expectedPieceSha),
                    $"Invalid piece checksum for '{name}'.");
                Require(expectedPieceSize.HasValue && expectedPieceSize.Value > 0, $"Invalid piece size for '{name}'.");

                var piecePath = Path.Combine(inputDir, name);
                Require(File.Exists(piecePath), $"Missing release archive piece: {piecePath}");

                using var partHasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                long actualPieceBytes = 0;

                using (var source = File.OpenRead(piecePath))
                {
                    int read;
                    while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        output.Write(buffer, 0, read);
                        partHasher.AppendData(buffer, 0, read);
                        fullHasher.AppendData(buffer, 0, read);
                        actualPieceBytes += read;
                        totalBytes += read;
                    }
                }

                var actualPieceSha = Convert.ToHexString(partHasher.GetHashAndReset()).ToLowerInvariant();
                Require(actualPieceBytes == expectedPieceSize.Value && string.Equals(actualPieceSha, expectedPieceSha, StringComparison.Ordinal),
                    $"Piece '{name}' differs from verified release record.");
            }
        }

        var actualArchiveSha = Convert.ToHexString(fullHasher.GetHashAndReset()).ToLowerInvariant();
        Require(string.Equals(actualArchiveSha, expectedArchiveSha, StringComparison.Ordinal),
            $"Reassembled archive checksum mismatch: expected {expectedArchiveSha}, found {actualArchiveSha}.");
        if (expectedArchiveBytes.HasValue)
        {
            Require(totalBytes == expectedArchiveBytes.Value,
                $"Reassembled archive size mismatch: expected {expectedArchiveBytes.Value}, found {totalBytes}.");
        }

        if (checksumPath is not null)
        {
            CheckSeal(outputPath, checksumPath);
        }

        WriteSeal(outputPath);
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            archiveSha256 = actualArchiveSha,
            archiveBytes = totalBytes
        }));
    }

    private static void RunExtractLayout(string[] args)
    {
        var (positionals, options) = ParseArgs(args);
        Require(positionals.Count == 1, "Expected archive path.");
        var archivePath = Path.GetFullPath(positionals[0]);
        var outputDir = Path.GetFullPath(GetRequiredOption(options, "--output-dir"));

        // Verify tar structure and every blob SHA-256 before materializing.
        _ = OciArchive.Open(archivePath);
        Directory.CreateDirectory(outputDir);

        using var stream = File.OpenRead(archivePath);
        using var reader = new TarReader(stream, leaveOpen: false);
        TarEntry? entry;
        while ((entry = reader.GetNextEntry(copyData: false)) is not null)
        {
            if (entry.EntryType == TarEntryType.Directory)
            {
                continue;
            }

            var normalized = NormalizeMemberName(entry.Name);
            var relative = normalized.Replace('/', Path.DirectorySeparatorChar);
            var targetPath = Path.GetFullPath(Path.Combine(outputDir, relative));
            var fullOutputDir = outputDir.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            Require(targetPath.StartsWith(fullOutputDir, StringComparison.Ordinal), $"Unsafe extraction path '{normalized}'.");

            var parent = Path.GetDirectoryName(targetPath);
            if (!string.IsNullOrEmpty(parent))
            {
                Directory.CreateDirectory(parent);
            }

            Require(entry.DataStream is not null, $"OCI archive entry '{normalized}' has no data.");
            using var target = File.Create(targetPath);
            entry.DataStream.CopyTo(target);
        }

        Console.WriteLine(JsonSerializer.Serialize(new { layoutPath = outputDir }));
    }

    private static void WriteBytesEntry(TarWriter writer, string name, byte[] data)
    {
        using var memory = new MemoryStream(data, writable: false);
        var entry = new PaxTarEntry(TarEntryType.RegularFile, name)
        {
            DataStream = memory
        };
        writer.WriteEntry(entry);
    }

    private static string NormalizeMemberName(string rawName)
    {
        var name = rawName.StartsWith("./", StringComparison.Ordinal) ? rawName[2..] : rawName;
        Require(!string.IsNullOrEmpty(name)
                && !name.Contains('\\')
                && !name.StartsWith('/')
                && !name.Split('/').Contains("..", StringComparer.Ordinal),
            $"Unsafe OCI archive member '{rawName}'.");
        return name;
    }

    private static JsonElement GetPropertyCaseInsensitive(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return default;
        }
        foreach (var property in element.EnumerateObject())
        {
            if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                return property.Value;
            }
        }
        return default;
    }

    private static string? ReadStringCaseInsensitive(JsonElement element, string name)
    {
        var prop = GetPropertyCaseInsensitive(element, name);
        return prop.ValueKind == JsonValueKind.String ? prop.GetString() : null;
    }

    private static long? ReadInt64CaseInsensitive(JsonElement element, string name)
    {
        var prop = GetPropertyCaseInsensitive(element, name);
        return prop.ValueKind == JsonValueKind.Number && prop.TryGetInt64(out var value) ? value : null;
    }

    private sealed record VerificationIdentity(
        string Version,
        string DocfxVersion,
        string Revision,
        string Source,
        string? Platform);

    private sealed record VerificationResult(
        string IndexDigest,
        string[] Platforms,
        Dictionary<string, string> Configs);

    private sealed class OciArchive
    {
        private readonly string _path;
        private readonly Dictionary<string, long> _memberSizes;
        private readonly Dictionary<string, byte[]> _cachedMembers;
        private readonly byte[] _indexBytes;
        private readonly JsonDocument _indexDocument;

        public JsonElement IndexElement => _indexDocument.RootElement;

        private OciArchive(
            string path,
            Dictionary<string, long> memberSizes,
            Dictionary<string, byte[]> cachedMembers,
            byte[] indexBytes,
            JsonDocument indexDocument)
        {
            _path = path;
            _memberSizes = memberSizes;
            _cachedMembers = cachedMembers;
            _indexBytes = indexBytes;
            _indexDocument = indexDocument;
        }

        public static OciArchive Open(string path)
        {
            Require(File.Exists(path) && new FileInfo(path).Length > 0, $"OCI archive is missing or empty: {path}");

            var memberSizes = new Dictionary<string, long>(StringComparer.Ordinal);
            var cachedMembers = new Dictionary<string, byte[]>(StringComparer.Ordinal);
            var buffer = new byte[1024 * 1024];

            using (var stream = File.OpenRead(path))
            using (var reader = new TarReader(stream, leaveOpen: false))
            {
                TarEntry? entry;
                while ((entry = reader.GetNextEntry(copyData: false)) is not null)
                {
                    if (entry.EntryType == TarEntryType.Directory)
                    {
                        continue;
                    }

                    Require(entry.EntryType is TarEntryType.RegularFile or TarEntryType.V7RegularFile,
                        $"Unsafe tar member type '{entry.EntryType}' for '{entry.Name}'.");

                    var name = NormalizeMemberName(entry.Name);
                    Require(!memberSizes.ContainsKey(name), $"Duplicate tar member '{name}'.");

                    var isBlob = name.StartsWith("blobs/sha256/", StringComparison.Ordinal);
                    Require(name is "index.json" or "oci-layout" || isBlob,
                        $"Unexpected OCI archive member '{name}'.");

                    if (isBlob)
                    {
                        var expectedHex = name["blobs/sha256/".Length..];
                        Require(Sha256HexPattern.IsMatch(expectedHex), $"Invalid OCI blob path '{name}'.");
                    }

                    Require(entry.DataStream is not null, $"OCI archive entry '{name}' has no data.");

                    long actualSize = 0;
                    using var hasher = isBlob ? IncrementalHash.CreateHash(HashAlgorithmName.SHA256) : null;
                    MemoryStream? memory = null;
                    var shouldCache = name is "index.json" or "oci-layout" || entry.Length <= MaxCachedJsonBytes;
                    var isJsonCandidate = name is "index.json" or "oci-layout";

                    if (shouldCache)
                    {
                        memory = new MemoryStream();
                    }

                    int read;
                    while ((read = entry.DataStream.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        if (actualSize == 0 && !isJsonCandidate && buffer[0] == (byte)'{')
                        {
                            isJsonCandidate = true;
                        }

                        hasher?.AppendData(buffer, 0, read);
                        actualSize += read;

                        if (memory is not null)
                        {
                            if (isJsonCandidate && actualSize <= MaxCachedJsonBytes)
                            {
                                memory.Write(buffer, 0, read);
                            }
                            else
                            {
                                memory.Dispose();
                                memory = null;
                            }
                        }
                    }

                    if (isBlob)
                    {
                        var actualHex = Convert.ToHexString(hasher!.GetHashAndReset()).ToLowerInvariant();
                        Require(string.Equals(name, "blobs/sha256/" + actualHex, StringComparison.Ordinal),
                            $"Corrupt OCI blob '{name}': actual digest sha256:{actualHex}.");
                    }

                    memberSizes[name] = actualSize;
                    if (memory is not null)
                    {
                        cachedMembers[name] = memory.ToArray();
                        memory.Dispose();
                    }
                }
            }

            Require(memberSizes.ContainsKey("oci-layout"), "Missing oci-layout member.");
            Require(memberSizes.ContainsKey("index.json"), "Missing index.json member.");

            using (var layoutDoc = JsonDocument.Parse(cachedMembers["oci-layout"]))
            {
                var layoutRoot = layoutDoc.RootElement;
                Require(layoutRoot.ValueKind == JsonValueKind.Object
                        && layoutRoot.TryGetProperty("imageLayoutVersion", out var v)
                        && v.ValueKind == JsonValueKind.String
                        && v.GetString() == "1.0.0",
                    "Invalid OCI layout.");
            }

            var indexBytes = cachedMembers["index.json"];
            var indexDoc = JsonDocument.Parse(indexBytes);

            // Buildx exports a layout index that wraps the actual OCI image index.
            while (indexDoc.RootElement.ValueKind == JsonValueKind.Object
                   && indexDoc.RootElement.TryGetProperty("manifests", out var manifests)
                   && manifests.ValueKind == JsonValueKind.Array
                   && manifests.GetArrayLength() == 1
                   && ReadString(manifests[0], "mediaType") == OciIndexMediaType)
            {
                var descriptor = manifests[0];
                var blobBytes = ReadDescriptorBytes(path, memberSizes, cachedMembers, descriptor);
                indexDoc.Dispose();
                indexBytes = blobBytes;
                indexDoc = JsonDocument.Parse(indexBytes);
            }

            Require(ReadInt32(indexDoc.RootElement, "schemaVersion") == 2
                    && ReadString(indexDoc.RootElement, "mediaType") == OciIndexMediaType,
                "Expected an OCI image index.");

            return new OciArchive(path, memberSizes, cachedMembers, indexBytes, indexDoc);
        }

        private static byte[] ReadDescriptorBytes(
            string path,
            Dictionary<string, long> memberSizes,
            Dictionary<string, byte[]> cachedMembers,
            JsonElement descriptor)
        {
            var digest = ReadString(descriptor, "digest");
            var size = ReadInt64(descriptor, "size");
            Require(!string.IsNullOrEmpty(digest) && digest.StartsWith("sha256:", StringComparison.Ordinal)
                    && Sha256HexPattern.IsMatch(digest["sha256:".Length..]),
                $"Invalid OCI descriptor digest '{digest}'.");
            var blobName = "blobs/sha256/" + digest["sha256:".Length..];
            Require(memberSizes.TryGetValue(blobName, out var actualSize) && size.HasValue && actualSize == size.Value,
                $"Missing or truncated OCI content '{blobName}'.");

            if (cachedMembers.TryGetValue(blobName, out var cached))
            {
                return cached;
            }

            using var stream = File.OpenRead(path);
            using var reader = new TarReader(stream, leaveOpen: false);
            TarEntry? entry;
            while ((entry = reader.GetNextEntry(copyData: false)) is not null)
            {
                if (entry.EntryType == TarEntryType.Directory)
                {
                    continue;
                }
                if (string.Equals(NormalizeMemberName(entry.Name), blobName, StringComparison.Ordinal))
                {
                    using var memory = new MemoryStream();
                    entry.DataStream!.CopyTo(memory);
                    return memory.ToArray();
                }
            }

            throw new InvalidDataException($"Missing OCI content '{blobName}'.");
        }

        private JsonDocument ReadBlobJson(JsonElement descriptor)
        {
            var bytes = ReadDescriptorBytes(_path, _memberSizes, _cachedMembers, descriptor);
            return JsonDocument.Parse(bytes);
        }

        public List<string> GetRunnableArchitectures()
        {
            var architectures = new List<string>();
            foreach (var descriptor in GetArray(IndexElement, "manifests"))
            {
                var platform = GetProperty(descriptor, "platform");
                if (ReadString(platform, "os") == "linux")
                {
                    var arch = ReadString(platform, "architecture");
                    Require(!string.IsNullOrEmpty(arch), "Runnable manifest is missing platform.architecture.");
                    architectures.Add(arch!);
                }
            }
            return architectures;
        }

        public string GetPlatformConfigDigest(string architecture)
        {
            var matches = GetArray(IndexElement, "manifests")
                .Where(d =>
                {
                    var p = GetProperty(d, "platform");
                    return ReadString(p, "os") == "linux" && ReadString(p, "architecture") == architecture;
                })
                .ToArray();
            Require(matches.Length == 1, $"Expected one manifest for linux/{architecture}, found {matches.Length}.");
            using var manifestDoc = ReadBlobJson(matches[0]);
            var config = GetProperty(manifestDoc.RootElement, "config");
            var digest = ReadString(config, "digest");
            Require(!string.IsNullOrEmpty(digest) && digest.StartsWith("sha256:", StringComparison.Ordinal),
                "Manifest config is missing a valid SHA-256 digest.");
            return digest!;
        }

        public VerificationResult Verify(VerificationIdentity identity, string[] expectedPlatforms, string? expectedIndexDigest)
        {
            var indexDigest = "sha256:" + ComputeBytesSha256(_indexBytes);
            if (!string.IsNullOrEmpty(expectedIndexDigest))
            {
                Require(string.Equals(indexDigest, expectedIndexDigest, StringComparison.Ordinal),
                    $"Saved OCI index digest mismatch: expected {expectedIndexDigest}, found {indexDigest}.");
            }

            var manifests = GetArray(IndexElement, "manifests");
            var runnable = manifests.Where(d => ReadString(GetProperty(d, "platform"), "os") == "linux").ToArray();
            var actualPlatforms = runnable
                .Select(d => ReadString(GetProperty(d, "platform"), "architecture") ?? string.Empty)
                .Order(StringComparer.Ordinal)
                .ToArray();
            var sortedExpected = expectedPlatforms.Order(StringComparer.Ordinal).ToArray();
            Require(actualPlatforms.SequenceEqual(sortedExpected, StringComparer.Ordinal),
                $"Unexpected platform inventory: [{string.Join(", ", actualPlatforms)}], expected [{string.Join(", ", sortedExpected)}].");

            var runnableDigests = runnable
                .Select(d => ReadString(d, "digest") ?? string.Empty)
                .ToHashSet(StringComparer.Ordinal);

            foreach (var descriptor in manifests)
            {
                var platform = GetProperty(descriptor, "platform");
                if (ReadString(platform, "os") == "linux")
                {
                    continue;
                }

                var annotations = GetProperty(descriptor, "annotations");
                Require(ReadString(platform, "os") == "unknown"
                        && ReadString(platform, "architecture") == "unknown"
                        && ReadString(annotations, "vnd.docker.reference.type") == "attestation-manifest"
                        && runnableDigests.Contains(ReadString(annotations, "vnd.docker.reference.digest") ?? string.Empty),
                    "Unexpected runtime or unattached attestation in image index.");
            }

            var configs = new Dictionary<string, string>(StringComparer.Ordinal);

            foreach (var descriptor in runnable)
            {
                var arch = ReadString(GetProperty(descriptor, "platform"), "architecture")!;
                var manifestDigest = ReadString(descriptor, "digest")!;
                var manifestHex = manifestDigest["sha256:".Length..];

                using var manifestDoc = ReadBlobJson(descriptor);
                var manifestRoot = manifestDoc.RootElement;
                var configDescriptor = GetProperty(manifestRoot, "config");
                var configDigest = ReadString(configDescriptor, "digest")!;
                using var configDoc = ReadBlobJson(configDescriptor);
                var configRoot = configDoc.RootElement;

                Require(ReadString(configRoot, "os") == "linux"
                        && ReadString(configRoot, "architecture") == arch,
                    $"Config CPU mismatch for {arch}.");

                var labels = GetProperty(GetProperty(configRoot, "config"), "Labels");
                var requiredLabels = new Dictionary<string, string>(StringComparer.Ordinal)
                {
                    ["org.opencontainers.image.source"] = identity.Source,
                    ["org.opencontainers.image.revision"] = identity.Revision,
                    ["org.opencontainers.image.version"] = identity.Version,
                    ["net.codebelt.docfx.engine.version"] = identity.Version,
                    ["net.codebelt.docfx.cli.version"] = identity.DocfxVersion
                };

                foreach (var (key, expectedValue) in requiredLabels)
                {
                    var actualValue = ReadString(labels, key);
                    Require(string.Equals(actualValue, expectedValue, StringComparison.Ordinal),
                        $"Identity mismatch: label '{key}' expected '{expectedValue}', found '{actualValue ?? string.Empty}'.");
                }

                Require(!string.IsNullOrWhiteSpace(ReadString(labels, "org.opencontainers.image.created")),
                    "Missing build identity: org.opencontainers.image.created.");

                foreach (var layer in GetArray(manifestRoot, "layers"))
                {
                    var layerDigest = ReadString(layer, "digest");
                    var layerSize = ReadInt64(layer, "size");
                    Require(!string.IsNullOrEmpty(layerDigest) && layerDigest.StartsWith("sha256:", StringComparison.Ordinal),
                        "Invalid image layer descriptor.");
                    var blobName = "blobs/sha256/" + layerDigest["sha256:".Length..];
                    Require(_memberSizes.TryGetValue(blobName, out var actualSize) && layerSize.HasValue && actualSize == layerSize.Value,
                        $"Missing or truncated image layer '{blobName}'.");
                }

                var predicates = new HashSet<string>(StringComparer.Ordinal);
                foreach (var attestationDescriptor in manifests)
                {
                    var annotations = GetProperty(attestationDescriptor, "annotations");
                    if (!string.Equals(ReadString(annotations, "vnd.docker.reference.digest"), manifestDigest, StringComparison.Ordinal))
                    {
                        continue;
                    }

                    using var attDoc = ReadBlobJson(attestationDescriptor);
                    foreach (var layer in GetArray(attDoc.RootElement, "layers"))
                    {
                        using var statementDoc = ReadBlobJson(layer);
                        var statement = statementDoc.RootElement;

                        var subjectMatches = GetArray(statement, "subject")
                            .Any(s => string.Equals(ReadString(GetProperty(s, "digest"), "sha256"), manifestHex, StringComparison.Ordinal));
                        Require(subjectMatches, "Attestation subject mismatch.");

                        var predicateType = ReadString(statement, "predicateType");
                        Require(!string.IsNullOrEmpty(predicateType), "Attestation statement missing predicateType.");
                        var predicate = GetProperty(statement, "predicate");

                        if (predicateType == SpdxPredicateType)
                        {
                            Require(!string.IsNullOrWhiteSpace(ReadString(predicate, "spdxVersion"))
                                    && GetArray(predicate, "packages").Length > 0,
                                "Empty SBOM.");
                        }
                        else if (predicateType!.StartsWith(SlsaPredicatePrefix, StringComparison.Ordinal))
                        {
                            var hasBuildType = !string.IsNullOrWhiteSpace(ReadString(predicate, "buildType"));
                            var buildDef = GetProperty(predicate, "buildDefinition");
                            Require(hasBuildType || buildDef.ValueKind == JsonValueKind.Object, "Empty provenance.");

                            var parameters = GetProperty(GetProperty(GetProperty(buildDef, "externalParameters"), "request"), "args");
                            if (parameters.ValueKind != JsonValueKind.Object)
                            {
                                parameters = GetProperty(GetProperty(GetProperty(predicate, "invocation"), "parameters"), "args");
                            }

                            var expectedArgs = new Dictionary<string, string>(StringComparer.Ordinal)
                            {
                                ["build-arg:DOCFX_VERSION"] = identity.DocfxVersion,
                                ["label:org.opencontainers.image.version"] = identity.Version,
                                ["label:net.codebelt.docfx.engine.version"] = identity.Version,
                                ["label:net.codebelt.docfx.cli.version"] = identity.DocfxVersion,
                                ["label:org.opencontainers.image.revision"] = identity.Revision,
                                ["label:org.opencontainers.image.source"] = identity.Source
                            };

                            foreach (var (argKey, argExpected) in expectedArgs)
                            {
                                var actualArg = ReadString(parameters, argKey);
                                Require(string.Equals(actualArg, argExpected, StringComparison.Ordinal),
                                    $"Provenance build identity mismatch: {argKey}.");
                            }
                        }

                        predicates.Add(predicateType!);
                    }
                }

                Require(predicates.Contains(SpdxPredicateType)
                        && predicates.Any(p => p.StartsWith(SlsaPredicatePrefix, StringComparison.Ordinal)),
                    $"SBOM or provenance missing for {arch}.");

                configs[arch] = configDigest;
            }

            return new VerificationResult(indexDigest, actualPlatforms, configs);
        }

        private static JsonElement[] GetArray(JsonElement value, string propertyName)
        {
            if (value.ValueKind == JsonValueKind.Object
                && value.TryGetProperty(propertyName, out var property)
                && property.ValueKind == JsonValueKind.Array)
            {
                return property.EnumerateArray().ToArray();
            }
            return Array.Empty<JsonElement>();
        }

        private static JsonElement GetProperty(JsonElement value, string propertyName)
        {
            if (value.ValueKind == JsonValueKind.Object
                && value.TryGetProperty(propertyName, out var property))
            {
                return property;
            }
            return default;
        }

        private static string? ReadString(JsonElement value, string propertyName)
        {
            return value.ValueKind == JsonValueKind.Object
                && value.TryGetProperty(propertyName, out var property)
                && property.ValueKind == JsonValueKind.String
                    ? property.GetString()
                    : null;
        }

        private static int? ReadInt32(JsonElement value, string propertyName)
        {
            return value.ValueKind == JsonValueKind.Object
                && value.TryGetProperty(propertyName, out var property)
                && property.TryGetInt32(out var number)
                    ? number
                    : null;
        }

        private static long? ReadInt64(JsonElement value, string propertyName)
        {
            return value.ValueKind == JsonValueKind.Object
                && value.TryGetProperty(propertyName, out var property)
                && property.TryGetInt64(out var number)
                    ? number
                    : null;
        }
    }
}
