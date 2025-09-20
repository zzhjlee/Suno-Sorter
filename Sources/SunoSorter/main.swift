import Foundation

struct SongVersion {
    let url: URL
    let displayName: String
    let createdAt: Date?
    let fileSize: UInt64?

    var detailsDescription: String {
        var components: [String] = []
        if let createdAt {
            components.append("created \(format(date: createdAt))")
        }
        if let fileSize {
            components.append(format(size: fileSize))
        }
        return components.joined(separator: ", ")
    }
}

struct SequenceState: Codable {
    var nextIndex: Int = 1

    static let stateFileName = ".suno_sorter_state.json"

    static func load(from projectFolder: URL) -> SequenceState {
        let fileURL = projectFolder.appendingPathComponent(Self.stateFileName)
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: fileURL),
           let state = try? decoder.decode(SequenceState.self, from: data) {
            return state
        }
        return SequenceState()
    }

    mutating func consumeIndex() -> Int {
        let current = nextIndex
        nextIndex += 1
        return current
    }

    func save(to projectFolder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(self)
            let fileURL = projectFolder.appendingPathComponent(Self.stateFileName)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            fputs("Warning: Failed to persist sequence state: \(error)\n", stderr)
        }
    }
}

// MARK: - Helpers

func expandPath(_ path: String) -> String {
    if path.hasPrefix("~") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = path.dropFirst()
        return home + expanded
    }
    return path
}

func prompt(_ message: String) -> String? {
    print(message, terminator: " ")
    return readLine()
}

private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

func format(date: Date) -> String {
    return dateFormatter.string(from: date)
}

func format(size: UInt64) -> String {
    let units: [String] = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(size)
    var unitIndex = 0
    while value >= 1024, unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }
    return String(format: "%.1f %@", value, units[unitIndex])
}

func cleanTitle(_ name: String) -> String {
    var result = name

    if let regex = try? NSRegularExpression(pattern: "\\s*[\\(\\[].*[\\)\\]]\\s*$", options: [.caseInsensitive]) {
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }

    result = result.replacingOccurrences(of: "_", with: " ")
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)

    while result.contains("  ") {
        result = result.replacingOccurrences(of: "  ", with: " ")
    }

    return result
}

func normalizeName(_ name: String) -> String {
    var result = cleanTitle(name)
    result = result.replacingOccurrences(of: "-", with: " ")
    result = result.lowercased()
    return result
}

func safeComponent(from name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
    let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
    var result = String(scalars)
    while result.contains("  ") {
        result = result.replacingOccurrences(of: "  ", with: " ")
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

func collectSongVersions(from directory: URL) -> [String: [SongVersion]] {
    var grouped: [String: [SongVersion]] = [:]

    let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: resourceKeys) else {
        return grouped
    }

    for case let fileURL as URL in enumerator {
        if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            continue
        }
        guard fileURL.pathExtension.lowercased() == "wav" else { continue }
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        var normalizedKey = normalizeName(baseName)
        if normalizedKey.isEmpty {
            normalizedKey = baseName.lowercased()
        }
        let values = try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
        let created = values?.creationDate ?? values?.contentModificationDate
        let size = values?.fileSize.flatMap { UInt64($0) }
        let version = SongVersion(url: fileURL, displayName: baseName, createdAt: created, fileSize: size)
        grouped[normalizedKey, default: []].append(version)
    }

    return grouped
}

func chooseIndex(max: Int, label: String, excluding: Set<Int> = []) -> Int? {
    guard max > 0 else { return nil }
    while true {
        let message = "Enter the number for version \(label) (or press Return to skip):"
        guard let input = prompt(message), !input.isEmpty else { return nil }
        if let value = Int(input), value >= 1, value <= max {
            let index = value - 1
            if excluding.contains(index) {
                print("That option is already assigned. Please pick a different file or press Return to skip.")
                continue
            }
            return index
        }
        print("Invalid selection. Try again or press Return to skip.")
    }
}

func uniqueDestination(for proposedURL: URL) -> URL {
    let fileManager = FileManager.default
    var destination = proposedURL
    var counter = 1
    while fileManager.fileExists(atPath: destination.path) {
        let base = proposedURL.deletingPathExtension().lastPathComponent
        let ext = proposedURL.pathExtension
        let newName = "\(base)-\(counter)"
        destination = proposedURL.deletingLastPathComponent().appendingPathComponent(newName).appendingPathExtension(ext)
        counter += 1
    }
    return destination
}

func moveVersion(_ version: SongVersion, label: String, to projectFolder: URL, state: inout SequenceState) {
    let index = state.consumeIndex()
    let formattedIndex = String(format: "%04d", index)

    let baseComponent = safeComponent(from: cleanTitle(version.displayName))
    let cleanedBase = baseComponent.isEmpty ? "Track" : baseComponent
    let newFileName = "\(label)\(formattedIndex) - \(cleanedBase).wav"
    let destination = uniqueDestination(for: projectFolder.appendingPathComponent(newFileName))

    do {
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: version.url, to: destination)
        print("Moved \(version.url.lastPathComponent) -> \(destination.lastPathComponent)")
    } catch {
        fputs("Error: failed to move \(version.url.path) -> \(destination.path): \(error)\n", stderr)
        return
    }

    state.save(to: projectFolder)
}

// MARK: - Argument Parsing

struct Arguments {
    var sourcePath: String?
    var projectPath: String?

    init() {
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--source", "-s":
                sourcePath = iterator.next()
            case "--project", "-p":
                projectPath = iterator.next()
            case "--help", "-h":
                Arguments.printHelp()
                exit(EXIT_SUCCESS)
            default:
                continue
            }
        }
    }

    static func printHelp() {
        let help = """
        Suno Sorter
        ===========
        Organise Suno AI generated WAV files by pairing versions and renaming them.

        Usage: suno-sorter [--source <folder>] [--project <folder>]

        Options:
          --source, -s    Path to the folder that contains the generated WAV files.
          --project, -p   Destination project folder for renamed files.
          --help, -h      Show this help message.
        """
        print(help)
    }
}

// MARK: - Main Execution

func main() {
    print("Suno Sorter")
    print("============\n")

    let arguments = Arguments()

    let sourcePath = arguments.sourcePath ?? {
        while true {
            if let input = prompt("Enter the path to your Suno output folder:"), !input.isEmpty {
                return expandPath(input)
            }
            print("A source folder is required.")
        }
    }()

    let projectPath = arguments.projectPath ?? {
        if let input = prompt("Enter the destination project folder (will be created if needed):"), !input.isEmpty {
            return expandPath(input)
        }
        print("A project folder is required.")
        exit(EXIT_FAILURE)
    }()

    let sourceURL = URL(fileURLWithPath: sourcePath)
    let projectURL = URL(fileURLWithPath: projectPath)

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        fputs("Error: Source path is not a folder.\n", stderr)
        exit(EXIT_FAILURE)
    }

    let groups = collectSongVersions(from: sourceURL)
    if groups.isEmpty {
        print("No WAV files were found in \(sourceURL.path).")
        exit(EXIT_SUCCESS)
    }

    var state = SequenceState.load(from: projectURL)

    let sortedKeys = groups.keys.sorted()
    for key in sortedKeys {
        guard let versions = groups[key] else { continue }
        let sortedVersions = versions.sorted { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (l?, r?):
                return l < r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.displayName < rhs.displayName
            }
        }

        let groupTitle = cleanTitle(sortedVersions.first?.displayName ?? key)
        print("\n=== Song Group: \(groupTitle) ===")
        for (index, version) in sortedVersions.enumerated() {
            var description = "  [\(index + 1)] \(version.url.lastPathComponent)"
            let details = version.detailsDescription
            if !details.isEmpty {
                description += " (\(details))"
            }
            print(description)
        }

        var chosenIndices = Set<Int>()
        if let indexA = chooseIndex(max: sortedVersions.count, label: "A") {
            chosenIndices.insert(indexA)
            moveVersion(sortedVersions[indexA], label: "A", to: projectURL, state: &state)
        }

        if sortedVersions.count > 1 && sortedVersions.count - chosenIndices.count > 0 {
            if let indexB = chooseIndex(max: sortedVersions.count, label: "B", excluding: chosenIndices) {
                chosenIndices.insert(indexB)
                moveVersion(sortedVersions[indexB], label: "B", to: projectURL, state: &state)
            }
        }
    }

    print("\nAll done! Remaining files were left untouched in the source folder.")
}

main()
