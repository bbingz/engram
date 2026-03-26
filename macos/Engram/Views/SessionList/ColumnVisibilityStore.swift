// macos/Engram/Views/SessionList/ColumnVisibilityStore.swift
import SwiftUI
import Observation

/// Persists per-column visibility for the session table via @AppStorage.
@Observable
final class ColumnVisibilityStore {
    @ObservationIgnored @AppStorage("col.favorite") var favorite = true
    @ObservationIgnored @AppStorage("col.agent")    var agent    = true
    @ObservationIgnored @AppStorage("col.title")    var title    = true
    @ObservationIgnored @AppStorage("col.date")     var date     = true
    @ObservationIgnored @AppStorage("col.project")  var project  = true
    @ObservationIgnored @AppStorage("col.msgs")     var msgs     = true
    @ObservationIgnored @AppStorage("col.size")     var size     = true
}
