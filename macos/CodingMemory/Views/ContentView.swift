// macos/CodingMemory/Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Text("CodingMemory")
                .font(.headline)
            Text("Loading...")
                .foregroundStyle(.secondary)
        }
        .frame(width: 300, height: 200)
        .padding()
    }
}
