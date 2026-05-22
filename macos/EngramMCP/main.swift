import Foundation

Task {
    await MCPStdioServer().run()
    exit(0)
}
dispatchMain()
