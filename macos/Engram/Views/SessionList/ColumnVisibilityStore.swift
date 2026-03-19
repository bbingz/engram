// macos/Engram/Views/SessionList/ColumnVisibilityStore.swift
import SwiftUI

/// Persists per-column visibility for the session table via @AppStorage.
final class ColumnVisibilityStore: ObservableObject {
    @AppStorage("col.favorite") var favorite = true
    @AppStorage("col.agent")    var agent    = true
    @AppStorage("col.title")    var title    = true
    @AppStorage("col.date")     var date     = true
    @AppStorage("col.project")  var project  = true
    @AppStorage("col.msgs")     var msgs     = true
    @AppStorage("col.size")     var size     = true
}
