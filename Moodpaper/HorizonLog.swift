import Foundation

/// Debug-only logger. All calls compile away to nothing in Release builds.
@inline(__always)
func HorizonLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
