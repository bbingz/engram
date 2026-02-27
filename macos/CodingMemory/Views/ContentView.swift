// macos/CodingMemory/Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess

    var body: some View {
        VStack(spacing: 12) {
            Text("CodingMemory")
                .font(.headline)
            Text(indexer.status.displayString)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .frame(width: 300, height: 200)
        .padding()
    }
}
