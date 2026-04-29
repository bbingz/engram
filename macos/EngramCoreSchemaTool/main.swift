import EngramCoreWrite
import Foundation

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 2 else {
        throw ToolError.usage("usage: EngramCoreSchemaTool migrate <db-path>")
    }
    guard args[0] == "migrate" else {
        throw ToolError.usage("unknown command: \(args[0])")
    }
    let writer = try EngramDatabaseWriter(path: args[1])
    try writer.migrate()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    Foundation.exit(1)
}

private enum ToolError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case let .usage(message):
            message
        }
    }
}
