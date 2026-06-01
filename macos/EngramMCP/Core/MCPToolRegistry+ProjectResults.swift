import Foundation

func orderedProjectMoveResult(
    from raw: JSONValue,
    resolved: (src: String, dst: String)?
) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    var entries = orderedPipelineEntries(from: object)
    if let resolved {
        entries.append((
            "resolved",
            .object([
                ("src", .string(resolved.src)),
                ("dst", .string(resolved.dst)),
            ])
        ))
    }
    return .object(entries)
}

func orderedProjectMoveResult(
    from result: EngramServiceProjectMoveResult,
    resolved: (src: String, dst: String)?
) -> OrderedJSONValue {
    var entries = orderedPipelineEntries(from: result)
    if let resolved {
        entries.append((
            "resolved",
            .object([
                ("src", .string(resolved.src)),
                ("dst", .string(resolved.dst)),
            ])
        ))
    }
    return .object(entries)
}

func orderedProjectArchiveResult(from raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else {
        return OrderedJSONValue(raw)
    }
    var entries = orderedPipelineEntries(from: object)
    if let suggestion = object["suggestion"] {
        entries.append(("archive", orderedArchiveSuggestion(from: suggestion)))
    }
    return .object(entries)
}

func orderedProjectArchiveResult(from result: EngramServiceProjectMoveResult) -> OrderedJSONValue {
    var entries = orderedPipelineEntries(from: result)
    if let suggestion = result.suggestion {
        entries.append(("archive", orderedArchiveSuggestion(suggestion)))
    }
    return .object(entries)
}

func orderedProjectMoveBatchResult(from raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    return .object([
        ("completed", .array(object["completed"]?.arrayValue?.map(orderedPipelineResultWithoutExtras) ?? [])),
        ("failed", OrderedJSONValue(object["failed"] ?? .array([]))),
        ("skipped", OrderedJSONValue(object["skipped"] ?? .array([]))),
    ])
}

func orderedPipelineResult(from raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    return .object(orderedPipelineEntries(from: object))
}

func orderedPipelineResult(from result: EngramServiceProjectMoveResult) -> OrderedJSONValue {
    .object(orderedPipelineEntries(from: result))
}

private func orderedPipelineResultWithoutExtras(_ raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    return .object(orderedPipelineEntries(from: object))
}

private func orderedPipelineEntries(from object: [String: JSONValue]) -> [(String, OrderedJSONValue)] {
    var entries: [(String, OrderedJSONValue)] = []
    if let migrationId = object["migrationId"] {
        entries.append(("migrationId", OrderedJSONValue(migrationId)))
    }
    if let state = object["state"] {
        entries.append(("state", OrderedJSONValue(state)))
    }
    if let moveStrategy = object["moveStrategy"] {
        entries.append(("moveStrategy", OrderedJSONValue(moveStrategy)))
    }
    if let ccDirRenamed = object["ccDirRenamed"] {
        entries.append(("ccDirRenamed", OrderedJSONValue(ccDirRenamed)))
    }
    if let renamedDirs = object["renamedDirs"] {
        entries.append(("renamedDirs", OrderedJSONValue(renamedDirs)))
    }
    if let skippedDirs = object["skippedDirs"]?.arrayValue {
        entries.append(("skippedDirs", .array(skippedDirs.map(orderedSkippedDir))))
    }
    if let perSource = object["perSource"]?.arrayValue {
        entries.append(("perSource", .array(perSource.map(orderedPerSourceResult))))
    }
    if let totalFilesPatched = object["totalFilesPatched"] {
        entries.append(("totalFilesPatched", OrderedJSONValue(totalFilesPatched)))
    }
    if let totalOccurrences = object["totalOccurrences"] {
        entries.append(("totalOccurrences", OrderedJSONValue(totalOccurrences)))
    }
    if let sessionsUpdated = object["sessionsUpdated"] {
        entries.append(("sessionsUpdated", OrderedJSONValue(sessionsUpdated)))
    }
    if let aliasCreated = object["aliasCreated"] {
        entries.append(("aliasCreated", OrderedJSONValue(aliasCreated)))
    }
    if let review = object["review"]?.objectValue {
        entries.append((
            "review",
            .object([
                ("own", OrderedJSONValue(review["own"] ?? .array([]))),
                ("other", OrderedJSONValue(review["other"] ?? .array([]))),
            ])
        ))
    }
    if let git = object["git"]?.objectValue {
        entries.append((
            "git",
            .object([
                ("isGitRepo", OrderedJSONValue(git["isGitRepo"] ?? .bool(false))),
                ("dirty", OrderedJSONValue(git["dirty"] ?? .bool(false))),
                ("untrackedOnly", OrderedJSONValue(git["untrackedOnly"] ?? .bool(false))),
                ("porcelain", OrderedJSONValue(git["porcelain"] ?? .string(""))),
            ])
        ))
    }
    if let manifest = object["manifest"] {
        entries.append(("manifest", OrderedJSONValue(manifest)))
    }
    return entries
}

private func orderedSkippedDir(_ raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    return .object([
        ("sourceId", OrderedJSONValue(object["sourceId"] ?? .null)),
        ("reason", OrderedJSONValue(object["reason"] ?? .null)),
    ])
}

private func orderedPerSourceResult(_ raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    return .object([
        ("id", OrderedJSONValue(object["id"] ?? .null)),
        ("root", OrderedJSONValue(object["root"] ?? .null)),
        ("filesPatched", OrderedJSONValue(object["filesPatched"] ?? .int(0))),
        ("occurrences", OrderedJSONValue(object["occurrences"] ?? .int(0))),
        ("issues", OrderedJSONValue(object["issues"] ?? .array([]))),
    ])
}

private func orderedArchiveSuggestion(from raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    return .object([
        ("category", OrderedJSONValue(object["category"] ?? .null)),
        ("reason", OrderedJSONValue(object["reason"] ?? .null)),
        ("dst", OrderedJSONValue(object["dst"] ?? .null)),
    ])
}

private func orderedPipelineEntries(from result: EngramServiceProjectMoveResult) -> [(String, OrderedJSONValue)] {
    var entries: [(String, OrderedJSONValue)] = [
        ("migrationId", .string(result.migrationId)),
        ("state", .string(result.state)),
    ]
    if let moveStrategy = result.moveStrategy {
        entries.append(("moveStrategy", .string(moveStrategy)))
    }
    entries.append(("ccDirRenamed", .bool(result.ccDirRenamed)))
    if let renamedDirs = result.renamedDirs {
        entries.append(("renamedDirs", OrderedJSONValue.jsonArray(renamedDirs)))
    }
    if let skippedDirs = result.skippedDirs {
        entries.append(("skippedDirs", .array(skippedDirs.map(orderedSkippedDir))))
    }
    if let perSource = result.perSource {
        entries.append(("perSource", .array(perSource.map(orderedPerSourceResult))))
    }
    entries.append(("totalFilesPatched", .int(result.totalFilesPatched)))
    entries.append(("totalOccurrences", .int(result.totalOccurrences)))
    entries.append(("sessionsUpdated", .int(result.sessionsUpdated)))
    entries.append(("aliasCreated", .bool(result.aliasCreated)))
    entries.append((
        "review",
        .object([
            ("own", OrderedJSONValue.jsonArray(result.review.own)),
            ("other", OrderedJSONValue.jsonArray(result.review.other)),
        ])
    ))
    if let git = result.git {
        entries.append((
            "git",
            .object([
                ("isGitRepo", .bool(git.isGitRepo)),
                ("dirty", .bool(git.dirty)),
                ("untrackedOnly", .bool(git.untrackedOnly)),
                ("porcelain", .string(git.porcelain)),
            ])
        ))
    }
    if let manifest = result.manifest {
        entries.append(("manifest", .array(manifest.map(orderedManifestEntry))))
    }
    return entries
}

private func orderedManifestEntry(_ entry: EngramServiceProjectMoveResult.ManifestEntry) -> OrderedJSONValue {
    .object([
        ("path", .string(entry.path)),
        ("occurrences", .int(entry.occurrences)),
    ])
}

private func orderedSkippedDir(_ item: EngramServiceProjectMoveResult.SkippedDir) -> OrderedJSONValue {
    .object([
        ("sourceId", .string(item.sourceId)),
        ("reason", .string(item.reason)),
    ])
}

private func orderedPerSourceResult(_ item: EngramServiceProjectMoveResult.PerSource) -> OrderedJSONValue {
    .object([
        ("id", .string(item.id)),
        ("root", .string(item.root)),
        ("filesPatched", .int(item.filesPatched)),
        ("occurrences", .int(item.occurrences)),
        ("issues", .array((item.issues ?? []).map(orderedWalkIssue))),
    ])
}

private func orderedWalkIssue(_ item: EngramServiceProjectMoveResult.PerSource.WalkIssue) -> OrderedJSONValue {
    var entries: [(String, OrderedJSONValue)] = [
        ("path", .string(item.path)),
        ("reason", .string(item.reason)),
    ]
    if let detail = item.detail {
        entries.append(("detail", .string(detail)))
    }
    return .object(entries)
}

private func orderedArchiveSuggestion(_ suggestion: EngramServiceProjectMoveResult.ArchiveSuggestion) -> OrderedJSONValue {
    .object([
        ("category", suggestion.category.map(OrderedJSONValue.string) ?? .null),
        ("reason", .string(suggestion.reason)),
        ("dst", .string(suggestion.dst)),
    ])
}

private extension OrderedJSONValue {
    static func jsonArray(_ values: [String]) -> OrderedJSONValue {
        .array(values.map(OrderedJSONValue.string))
    }
}
