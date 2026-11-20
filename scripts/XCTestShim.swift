// Minimal XCTest-compatible shim for machines with only partial Command Line Tools
// (no XCTest.framework). Supports the subset of XCTest used by MacAudioOo's tests.
// Not used when a full Xcode toolchain is available (swift test / xcodebuild).
import Foundation
import ObjectiveC

var shimFailures = 0

@objcMembers class XCTestCase: NSObject {
    required override init() { super.init() }
    func setUp() {}
    func tearDown() {}
}

func XCTAssertTrue(_ e: @autoclosure () -> Bool, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    if !e() { shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertTrue \(m)") }
}
func XCTAssertFalse(_ e: @autoclosure () -> Bool, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    if e() { shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertFalse \(m)") }
}
func XCTAssertNil(_ e: @autoclosure () -> Any?, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    if e() != nil { shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertNil \(m)") }
}
func XCTAssertNotNil(_ e: @autoclosure () -> Any?, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    if e() == nil { shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertNotNil \(m)") }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    let x = a(), y = b()
    if x != y { shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertEqual \(x) != \(y) \(m)") }
}
func XCTAssertEqual<T: BinaryFloatingPoint>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, accuracy: T, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    let x = a(), y = b()
    if abs(x - y) > accuracy { shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertEqual \(x) != \(y) (±\(accuracy)) \(m)") }
}
func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, file: StaticString = #file, line: UInt = #line) {
    let x = a(), y = b()
    if !(x < y) { shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertLessThan \(x) !< \(y)") }
}
func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, file: StaticString = #file, line: UInt = #line) {
    let x = a(), y = b()
    if !(x > y) { shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertGreaterThan \(x) !> \(y)") }
}

func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    let x = a(), y = b()
    if x == y { shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertNotEqual \(x) == \(y) \(m)") }
}
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, file: StaticString = #file, line: UInt = #line) {
    let x = a(), y = b()
    if !(x >= y) { shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertGreaterThanOrEqual \(x) !>= \(y)") }
}
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, file: StaticString = #file, line: UInt = #line) {
    let x = a(), y = b()
    if !(x <= y) { shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertLessThanOrEqual \(x) !<= \(y)") }
}

struct XCTSkipOrFail: Error { var message: String }

func XCTFail(_ m: String = "", file: StaticString = #file, line: UInt = #line) {
    shimFailures += 1; print("  FAIL \(file):\(line) XCTFail \(m)")
}
func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?, _ m: String = "", file: StaticString = #file, line: UInt = #line) throws -> T {
    if let v = try e() { return v }
    shimFailures += 1; print("  FAIL \(file):\(line) XCTUnwrap found nil \(m)")
    throw XCTSkipOrFail(message: "nil")
}
func XCTAssertThrowsError<T>(_ e: @autoclosure () throws -> T, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    do { _ = try e(); shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertThrowsError did not throw \(m)") } catch {}
}
func XCTAssertNoThrow<T>(_ e: @autoclosure () throws -> T, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    do { _ = try e() } catch { shimFailures += 1; print("  FAIL \(file):\(line) XCTAssertNoThrow threw \(error) \(m)") }
}

private typealias ThrowingIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool

/// Finds every XCTestCase subclass and runs its `test*` methods.
func runAllShimTests(_ types: [XCTestCase.Type]) -> Int32 {
    var ran = 0
    for type in types {
        let cls: AnyClass = type
        var mcount: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &mcount) else { continue }
        for j in 0..<Int(mcount) {
            let sel = method_getName(methods[j])
            let name = NSStringFromSelector(sel)
            guard name.hasPrefix("test") else { continue }
            let before = shimFailures
            var shownName = name
            if !name.contains(":") {
                let inst = type.init(); inst.setUp(); _ = inst.perform(sel); inst.tearDown()
            } else if name.hasSuffix("AndReturnError:") {
                // `func testX() throws` is exposed to Objective-C as -testXAndReturnError:
                shownName = String(name.dropLast("AndReturnError:".count))
                let inst = type.init(); inst.setUp()
                let imp = unsafeBitCast(method_getImplementation(methods[j]), to: ThrowingIMP.self)
                var err: NSError?
                if !imp(inst, sel, &err) {
                    if err != nil && shimFailures == before { shimFailures += 1; print("  FAIL \(name) threw \(String(describing: err))") }
                }
                inst.tearDown()
            } else { continue }
            ran += 1
            print("\(shimFailures == before ? "PASS" : "FAIL") \(NSStringFromClass(cls)).\(shownName)")
        }
    }
    print("Executed \(ran) tests, \(shimFailures) failures")
    return (shimFailures == 0 && ran > 0) ? 0 : 1
}
