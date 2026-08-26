import ArgumentParser
import Foundation

struct SolLaunchOptions: ParsableArguments {
    @Flag(name: .long, help: "Show Sol's setup assistant on this launch.")
    var showOnboarding = false

    @Flag(name: .long, help: "Clear first-run setup state and start again.")
    var resetOnboarding = false

    init() {}

    static func current(arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> Self {
        // AppKit and Xcode append their own process arguments. Only hand the
        // options owned by Sol to ArgumentParser so a GUI launch can never be
        // aborted by an unrelated system flag.
        let supported = Set(["--show-onboarding", "--reset-onboarding"])
        let solArguments = arguments.filter(supported.contains)
        if let parsed = try? parse(solArguments) {
            return parsed
        }
        // The filtered empty argument set is always valid for these optional
        // flags and, unlike `init()`, contains resolved wrapper values.
        return try! parse([])
    }
}
