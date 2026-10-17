import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct InterfaceModeTests {
    @Test func advancedHasEverything() {
        #expect(Feature.available(in: .advanced) == Set(Feature.allCases))
        for feature in Feature.allCases { #expect(feature.isAvailable(in: .advanced), "\(feature)") }
    }

    @Test func simpleIsASubsetOfAdvanced() {
        let simple = Feature.available(in: .simple)
        #expect(simple.isSubset(of: Feature.available(in: .advanced)))
        #expect(simple.count < Feature.allCases.count)
        #expect(!simple.isEmpty)
    }

    /// The Simple decisions, pinned: changing one is a product decision, so this list changes with it.
    @Test func simpleKeepsTheEverydayCore() {
        let expected: Set<Feature> = [
            .connections, .uriConnections, .connectionSSLAndSSH, .navigator, .objectsList, .tableData, .filterAndSort,
            .formView, .valueEditor, .copyAs, .exportData, .importData, .queryEditor, .explain, .queryHistory,
            .savedQueries, .codeSnippets, .designTable, .tableOperations, .dumpAndExecuteSQL, .aiAssistant, .askAI,
            .infoPane,
        ]
        #expect(Feature.available(in: .simple) == expected)
    }

    @Test func simpleHidesTheSpecialistTools() {
        let hidden: [Feature] = [.bi, .automation, .model, .backup, .users, .otherObjects, .routineObjectButtons,
                                 .dataTransfer, .structureSync, .dataSync, .dataGeneration, .dataProfiling, .dataMasking,
                                 .tableProfile, .queryBuilder, .transactionMode, .aiCompare, .cloudCatalog,
                                 .connectionAdvancedTabs, .designTableExtras, .objectsGrid, .advancedSettings]
        for feature in hidden {
            #expect(!feature.isAvailable(in: .simple), "\(feature)")
            #expect(feature.minimumMode == .advanced)
        }
        // Every feature is either kept or hidden: nothing undecided.
        #expect(Set(hidden).union(Feature.available(in: .simple)) == Set(Feature.allCases))
    }

    @Test func modeRoundTripsAsItsRawValue() throws {
        #expect(InterfaceMode(rawValue: "simple") == .simple)
        #expect(InterfaceMode(rawValue: "advanced") == .advanced)
        #expect(InterfaceMode(rawValue: "expert") == nil)
        let data = try JSONEncoder().encode([InterfaceMode.simple])
        #expect(String(decoding: data, as: UTF8.self) == "[\"simple\"]")
        #expect(InterfaceMode.allCases.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty })
    }

    @Test func onboardingOnlyOnAFreshFirstLaunch() {
        #expect(OnboardingDecision.resolve(completed: false, hasSavedConnections: false, hasSavedSettings: false) == .show)
        #expect(OnboardingDecision.resolve(completed: true, hasSavedConnections: false, hasSavedSettings: false) == .skip)
        // People who used BunnyGrid before the choice existed keep Advanced without being asked.
        #expect(OnboardingDecision.resolve(completed: false, hasSavedConnections: true, hasSavedSettings: false) == .skipExistingUser)
        #expect(OnboardingDecision.resolve(completed: false, hasSavedConnections: false, hasSavedSettings: true) == .skipExistingUser)
        // A launch that opens a file or runs a scenario is not interrupted, and asks next time.
        #expect(OnboardingDecision.resolve(completed: false, hasSavedConnections: false, hasSavedSettings: false, suppressed: true) == .skip)
        // --onboarding always shows it.
        #expect(OnboardingDecision.resolve(completed: true, hasSavedConnections: true, hasSavedSettings: true, forced: true) == .show)
    }
}
