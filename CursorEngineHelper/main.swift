import Foundation

let status = autoreleasepool {
    HelperEventPolicy.route(
        arguments: CommandLine.arguments,
        probe: { HelperTrustProbe.childMain() },
        runtime: {
            let runtime = HelperRuntime()
            runtime.run()
        }
    )
}
exit(status)
