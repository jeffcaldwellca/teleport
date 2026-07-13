import ArgumentParser

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Suppress non-error output.")
    var quiet = false
}
