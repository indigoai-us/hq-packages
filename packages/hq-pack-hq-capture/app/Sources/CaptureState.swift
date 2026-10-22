import SwiftUI

// SDK 27 also exports a State macro, but Command Line Tools do not ship its
// SwiftUIMacros plugin. Select the existing property-wrapper type explicitly.
// A type alias preserves SwiftUI state storage, DynamicProperty updates and
// projected bindings on both SDK 26 and 27 without a custom wrapper.
typealias CaptureState<Value> = SwiftUI.State<Value>
