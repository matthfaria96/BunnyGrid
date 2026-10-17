import Foundation

/// How much of the app the person sees. Advanced is everything; Simple keeps what a developer uses every day
/// (connect, browse, edit, query, export) and hides the specialist tools. Switching never deletes anything.
public enum InterfaceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case simple, advanced

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .simple: "Simple"
        case .advanced: "Advanced"
        }
    }

    public var summary: String {
        switch self {
        case .simple: "Just the essentials: connect, browse, edit and query."
        case .advanced: "Everything: modeling, BI, automation, sync and more."
        }
    }
}

/// Every switchable part of the app, with one explicit decision per mode. Toolbar buttons, menu items, keyboard
/// shortcuts, context menus, wizards, editor tabs and Settings pages ask this table instead of the mode itself.
public enum Feature: String, CaseIterable, Sendable {
    // MARK: Everyday core (Simple and Advanced)
    case connections
    case uriConnections
    case connectionSSLAndSSH
    case navigator
    case objectsList
    case tableData
    case filterAndSort
    case formView
    case valueEditor
    case copyAs
    case exportData
    case importData
    case queryEditor
    case explain
    case queryHistory
    case savedQueries
    case codeSnippets
    case designTable
    case tableOperations
    case dumpAndExecuteSQL
    case aiAssistant
    case askAI
    case infoPane

    // MARK: Advanced only
    /// Main toolbar BI, BI workspaces and Create BI Workspace.
    case bi
    case automation
    /// Model / ER diagrams (Reverse Database to Model).
    case model
    case backup
    /// User and role manager.
    case users
    /// The Others menu (sequences, types, events…).
    case otherObjects
    /// Toolbar buttons for functions, materialized views, indexes, triggers and GridFS; the objects stay listed.
    case routineObjectButtons
    case dataTransfer
    case structureSync
    case dataSync
    case dataGeneration
    case dataProfiling
    case dataMasking
    case tableProfile
    case queryBuilder
    case transactionMode
    case aiCompare
    /// Hosted services and vendors in New Connection (AWS, Azure, Google Cloud…).
    case cloudCatalog
    /// Connection editor Advanced, Databases, HTTP and Remarks tabs.
    case connectionAdvancedTabs
    /// Design Table Uniques, Triggers and Options.
    case designTableExtras
    /// Objects tab icon (grid) view.
    case objectsGrid
    /// Settings Tabs, Code Completion, Auto Recovery and Advanced pages, and the advanced Records options.
    case advancedSettings

    /// The least the mode must be for this feature to show. Exhaustive on purpose: a new feature must decide.
    public var minimumMode: InterfaceMode {
        switch self {
        case .connections, .uriConnections, .connectionSSLAndSSH, .navigator, .objectsList, .tableData, .filterAndSort,
             .formView, .valueEditor, .copyAs, .exportData, .importData, .queryEditor, .explain, .queryHistory,
             .savedQueries, .codeSnippets, .designTable, .tableOperations, .dumpAndExecuteSQL, .aiAssistant, .askAI,
             .infoPane:
            .simple
        case .bi, .automation, .model, .backup, .users, .otherObjects, .routineObjectButtons, .dataTransfer,
             .structureSync, .dataSync, .dataGeneration, .dataProfiling, .dataMasking, .tableProfile, .queryBuilder,
             .transactionMode, .aiCompare, .cloudCatalog, .connectionAdvancedTabs, .designTableExtras, .objectsGrid,
             .advancedSettings:
            .advanced
        }
    }

    public func isAvailable(in mode: InterfaceMode) -> Bool {
        switch (minimumMode, mode) {
        case (.simple, _), (.advanced, .advanced): true
        case (.advanced, .simple): false
        }
    }

    public static func available(in mode: InterfaceMode) -> Set<Feature> {
        Set(allCases.filter { $0.isAvailable(in: mode) })
    }
}

/// What happens at launch with the welcome sheet.
public enum OnboardingDecision: Equatable, Sendable {
    /// First launch: ask for the mode and the appearance.
    case show
    /// Someone who used BunnyGrid before this choice existed: keep Advanced, never ask.
    case skipExistingUser
    /// Already answered.
    case skip

    /// - Parameters:
    ///   - completed: the saved "onboarding done" flag.
    ///   - hasSavedConnections: connections.json lists at least one connection.
    ///   - hasSavedSettings: options, appearance or other preferences from an earlier version exist.
    ///   - forced: `--onboarding` (debug).
    ///   - suppressed: launched to open something (a file, a debug flag, a UI scenario): don't cover it with a sheet.
    public static func resolve(completed: Bool, hasSavedConnections: Bool, hasSavedSettings: Bool,
                               forced: Bool = false, suppressed: Bool = false) -> OnboardingDecision {
        if forced { return .show }
        if completed { return .skip }
        if hasSavedConnections || hasSavedSettings { return .skipExistingUser }
        return suppressed ? .skip : .show
    }
}
