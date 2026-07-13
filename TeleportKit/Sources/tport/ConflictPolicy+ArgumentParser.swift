import ArgumentParser
import TeleportCLICore

/// `TeleportCLICore` deliberately doesn't depend on ArgumentParser (it stays
/// framework-free and fast to test), so this conformance lives here instead.
/// ArgumentParser provides a default `ExpressibleByArgument` implementation
/// for any `RawRepresentable` enum with `RawValue == String` — declaring the
/// (empty) conformance is enough to pick it up.
extension ConflictPolicy: ExpressibleByArgument {}
