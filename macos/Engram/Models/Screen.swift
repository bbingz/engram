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
    // Workspace
    case projects
    case sourcePulse
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
        case .projects:    return "Projects"
        case .sourcePulse: return "Source Pulse"
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
        case .projects:    return "folder"
        case .sourcePulse: return "antenna.radiowaves.left.and.right"
        case .skills:      return "sparkles"
        case .agents:      return "cpu"
        case .memory:      return "brain"
        case .hooks:       return "link"
        case .settings:    return "gear"
        }
    }

    /// Sidebar sections (Settings excluded — it's pinned to bottom)
    enum Section: String, CaseIterable {
        case overview  = "OVERVIEW"
        case monitor   = "MONITOR"
        case workspace = "WORKSPACE"
        case config    = "CONFIG"

        var screens: [Screen] {
            switch self {
            case .overview:  return [.home, .search]
            case .monitor:   return [.sessions, .timeline, .activity]
            case .workspace: return [.projects, .sourcePulse]
            case .config:    return [.skills, .agents, .memory, .hooks]
            }
        }
    }
}
