import Foundation

#if !canImport(Combine)
/// Linux stand-ins for Combine's observation types so SoulseekCore (which
/// uses `ObservableObject`/`@Published` for the iOS UI layer) still compiles
/// and runs its unit tests on Linux CI. On Apple platforms the real Combine
/// types are used and SwiftUI observation works as usual.
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    private var value: Value

    public var wrappedValue: Value {
        get { value }
        set { value = newValue }
    }

    public init(wrappedValue: Value) {
        value = wrappedValue
    }

    public init(initialValue: Value) {
        value = initialValue
    }
}
#endif
