// macos/Engram/Models/Screen.swift
import SwiftUI

enum Screen: String, CaseIterable, Identifiable, Hashable {
    // Overview
    case home
    case search
    // Monitor
    case sessions
    case timeline
    case activity
    case observability
    case hygiene
    // Workspace
    case projects
    case sourcePulse
    case repos
    case workGraph
    // Config
    case skills
    case agents
    case memory
    case hooks
    // System
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:        return "Home"
        case .search:      return "Search"
        case .sessions:    return "Sessions"
        case .timeline:    return "Timeline"
        case .activity:    return "Activity"
        case .observability: return "Observability"
        case .hygiene:       return "Hygiene"
        case .projects:    return "Projects"
        case .sourcePulse: return "Sources"
        case .repos:       return "Repos"
        case .workGraph:   return "Work Graph"
        case .skills:      return "Skills"
        case .agents:      return "Agents"
        case .memory:      return "Memory"
        case .hooks:       return "Hooks"
        case .settings:    return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home:        return "house"
        case .search:      return "magnifyingglass"
        case .sessions:    return "bubble.left.and.bubble.right"
        case .timeline:    return "chart.bar.xaxis"
        case .activity:    return "bolt"
        case .observability: return "gauge.open.with.lines.needle.33percent"
        case .hygiene:       return "cross.case"
        case .projects:    return "folder"
        case .sourcePulse: return "antenna.radiowaves.left.and.right"
        case .repos:       return "arrow.triangle.branch"
        case .workGraph:   return "point.3.connected.trianglepath.dotted"
        case .skills:      return "sparkles"
        case .agents:      return "cpu"
        case .memory:      return "brain"
        case .hooks:       return "link"
        case .settings:    return "gear"
        }
    }

    /// Sidebar sections
    enum Section: String, CaseIterable {
        case overview  = "OVERVIEW"
        case monitor   = "MONITOR"
        case workspace = "WORKSPACE"
        case config    = "CONFIG"
        case system    = "SYSTEM"

        var screens: [Screen] {
            switch self {
            case .overview:  return [.home, .search]
            case .monitor:   return [.sessions, .timeline, .activity, .observability, .hygiene]
            case .workspace: return [.projects, .sourcePulse, .repos, .workGraph]
            case .config:    return [.skills, .agents, .memory, .hooks]
            case .system:    return [.settings]
            }
        }
    }
}
