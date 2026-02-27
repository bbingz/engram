// macos/CodingMemory/Views/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @AppStorage("httpPort")   var httpPort:   Int    = 3456
    @AppStorage("nodejsPath") var nodejsPath: String = "/usr/local/bin/node"
    @EnvironmentObject var indexer: IndexerProcess

    var body: some View {
        Form {
            Section("MCP Server") {
                HStack {
                    Text("HTTP Port")
                    Spacer()
                    TextField("3456", value: $httpPort, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section("Node.js Indexer") {
                HStack {
                    Text("Node.js Path")
                    Spacer()
                    TextField("/usr/local/bin/node", text: $nodejsPath)
                        .frame(width: 200)
                }
                HStack {
                    Text("Status")
                    Spacer()
                    Text(indexer.status.displayString)
                        .foregroundStyle(.secondary)
                }
            }
            Section("About") {
                HStack {
                    Text("MCP HTTP endpoint")
                    Spacer()
                    Text("http://localhost:\(httpPort)/mcp")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .padding()
    }
}
