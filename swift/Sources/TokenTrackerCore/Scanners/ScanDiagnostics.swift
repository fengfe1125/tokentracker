import Foundation

/// A scan runs on one worker thread. Only counts escape this scope, never content.
final class ScanDiagnostics: NSObject {
    var parseErrors=0
    var readErrors=0
    static func begin() { Thread.current.threadDictionary["tt.scan.diagnostics"]=ScanDiagnostics() }
    static var current:ScanDiagnostics? { Thread.current.threadDictionary["tt.scan.diagnostics"] as? ScanDiagnostics }
}
