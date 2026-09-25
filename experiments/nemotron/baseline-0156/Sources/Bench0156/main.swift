import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: bench0156 sortformer --wav <path> [--start s] [--duration s] [--variant high-context|balanced|fast] [--models dir] [--out json]") }
let options = Options(args.dropFirst(2))
switch args[1] {
case "sortformer": try await runSortformer(options, fluidAudio: "0.15.6")
default: fail("未知のコマンド: \(args[1])")
}
