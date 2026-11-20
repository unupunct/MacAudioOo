import XCTest
import AppKit
@testable import MacAudioOo

final class AppIdentityTests: XCTestCase {
    /// Fake process table: pid -> (parent, regular-app info), plus running apps by bundle ID.
    struct World {
        var parents: [pid_t: pid_t] = [:]
        var regular: [pid_t: (String, String?)] = [:]
        var running: [String: (String, String?, pid_t)] = [:]
        var env: AppIdentityResolver.Env {
            AppIdentityResolver.Env(parent: { self.parents[$0] },
                                    regularApp: { p in self.regular[p].map { (name: $0.0, bundleID: $0.1) } },
                                    runningApp: { b in self.running[b].map { (name: $0.0, bundleID: $0.1, pid: $0.2) } })
        }
    }

    func testARegularApplicationIsItself() {
        var w = World(); w.regular[100] = ("Spotify", "com.spotify.client")
        let id = AppIdentityResolver.resolve(pid: 100, bundleHint: "com.spotify.client", env: w.env)
        XCTAssertEqual(id.name, "Spotify"); XCTAssertEqual(id.key, "com.spotify.client"); XCTAssertEqual(id.mainPID, 100)
    }

    func testHelperProcessResolvesThroughItsParentChain() {
        var w = World()
        w.regular[100] = ("Google Chrome", "com.google.Chrome")
        w.parents[200] = 100; w.parents[300] = 200                       // renderer -> helper -> Chrome
        let id = AppIdentityResolver.resolve(pid: 300, bundleHint: "com.google.Chrome.helper", env: w.env)
        XCTAssertEqual(id.name, "Google Chrome"); XCTAssertEqual(id.key, "com.google.Chrome"); XCTAssertEqual(id.mainPID, 100)
        // Two different helpers of the same app produce the same grouping key.
        let id2 = AppIdentityResolver.resolve(pid: 200, bundleHint: nil, env: w.env)
        XCTAssertEqual(id2.key, id.key)
    }

    func testHelperBundleIDFindsTheRunningApplicationWithoutAParentChain() {
        var w = World()
        w.running["com.hnc.Discord"] = ("Discord", "com.hnc.Discord", 400)
        let id = AppIdentityResolver.resolve(pid: 999, bundleHint: "com.hnc.Discord.helper.Renderer", env: w.env)
        XCTAssertEqual(id.name, "Discord"); XCTAssertEqual(id.mainPID, 400); XCTAssertEqual(id.key, "com.hnc.Discord")
    }

    func testWebKitServicesAreAttributedToSafariWhenSafariRuns() {
        var w = World()
        w.running["com.apple.Safari"] = ("Safari", "com.apple.Safari", 500)
        let gpu = AppIdentityResolver.resolve(pid: 601, bundleHint: "com.apple.WebKit.GPU", env: w.env)
        let web = AppIdentityResolver.resolve(pid: 602, bundleHint: "com.apple.WebKit.WebContent", env: w.env)
        XCTAssertEqual(gpu.name, "Safari"); XCTAssertEqual(gpu.key, web.key)           // one channel for all WebKit services
        // Safari not running: readable fallback, still grouped by family member.
        let lone = AppIdentityResolver.resolve(pid: 603, bundleHint: "com.apple.WebKit.GPU", env: World().env)
        XCTAssertEqual(lone.name, "WebKit GPU"); XCTAssertNil(lone.mainPID)
    }

    func testFallbacksAreReadableAndStable() {
        let w = World()
        XCTAssertEqual(AppIdentityResolver.resolve(pid: 77, bundleHint: nil, env: w.env).name, "Process 77")
        XCTAssertEqual(AppIdentityResolver.resolve(pid: 77, bundleHint: "", env: w.env).key, "pid:77")
        let h = AppIdentityResolver.resolve(pid: 78, bundleHint: "org.example.Thing.helper", env: w.env)   // app not running
        XCTAssertEqual(h.key, "org.example.Thing"); XCTAssertEqual(h.name, "Thing")
    }

    func testParentCyclesCannotLoopForever() {
        var w = World()
        w.parents[10] = 11; w.parents[11] = 10                          // impossible, but must not hang
        XCTAssertEqual(AppIdentityResolver.resolve(pid: 10, bundleHint: nil, env: w.env).name, "Process 10")
        w.parents[20] = 20
        XCTAssertEqual(AppIdentityResolver.resolve(pid: 20, bundleHint: nil, env: w.env).name, "Process 20")
    }

    func testBundleIDHelpers() {
        XCTAssertEqual(AppIdentityResolver.mainBundleID(fromHelper: "com.hnc.Discord.helper.Renderer"), "com.hnc.Discord")
        XCTAssertEqual(AppIdentityResolver.mainBundleID(fromHelper: "com.google.Chrome.helper"), "com.google.Chrome")
        XCTAssertEqual(AppIdentityResolver.mainBundleID(fromHelper: "com.microsoft.VSCode.Helper (GPU)"), "com.microsoft.VSCode")
        XCTAssertNil(AppIdentityResolver.mainBundleID(fromHelper: "com.spotify.client"))
        XCTAssertNil(AppIdentityResolver.mainBundleID(fromHelper: "helper"))
        XCTAssertEqual(AppIdentityResolver.prettyName("com.apple.WebKit.GPU"), "WebKit GPU")
        XCTAssertEqual(AppIdentityResolver.prettyName("org.example.Thing"), "Thing")
    }

    func testTheSystemResolverKnowsThisVeryProcess() {
        // Real lookup: a test runner is not a regular app, but its parent chain must resolve without crashing.
        let id = AppIdentityResolver.resolve(pid: ProcessInfo.processInfo.processIdentifier, bundleHint: nil)
        XCTAssertFalse(id.name.isEmpty); XCTAssertFalse(id.key.isEmpty)
    }

    // MARK: Grouped sources and channels

    final class ConstSource: ChannelSource {
        var value: Float
        init(_ v: Float) { value = v }
        override func pull(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
            for i in 0..<frames { l[i] = value; r[i] = -value }
        }
    }

    func pull(_ s: ChannelSource, frames: Int = 64) -> (Float, Float) {
        var l = [Float](repeating: 9, count: frames), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in s.pull(lp.baseAddress!, rp.baseAddress!, frames: frames) } }
        return (l[frames - 1], r[frames - 1])
    }

    func testGroupedSourceSumsItsMembers() {
        let g = GroupedSource()
        XCTAssertEqual(pull(g).0, 0)                                    // empty group is silent
        let a = ConstSource(0.1), b = ConstSource(0.25), c = ConstSource(0.5)
        XCTAssertTrue(g.add(a)); XCTAssertTrue(g.add(b)); XCTAssertTrue(g.add(c))
        XCTAssertEqual(pull(g).0, 0.85, accuracy: 1e-6); XCTAssertEqual(pull(g).1, -0.85, accuracy: 1e-6)
        g.remove(b)
        XCTAssertEqual(g.memberCount, 2)
        XCTAssertEqual(pull(g).0, 0.6, accuracy: 1e-6)
        g.remove(b)                                                     // removing twice is harmless
        XCTAssertEqual(g.memberCount, 2)
    }

    func testGroupedSourceHasAFixedCapacity() {
        let g = GroupedSource()
        for _ in 0..<GroupedSource.capacity { XCTAssertTrue(g.add(ConstSource(0.01))) }
        XCTAssertFalse(g.add(ConstSource(1)))
        XCTAssertEqual(pull(g).0, 0.16, accuracy: 1e-5)
    }

    func ident(_ key: String, _ name: String, pid: pid_t? = nil) -> AppIdentity { AppIdentity(key: key, name: name, bundleID: key, mainPID: pid) }

    func testOneChannelPerApplicationEvenWithManyProcesses() {
        let e = AudioEngine()
        let m = GroupedChannelManager(engine: e)
        let chrome = ident("com.google.Chrome", "Google Chrome", pid: 100), spotify = ident("com.spotify.client", "Spotify", pid: 200)
        m.reconcile(["com.google.Chrome": .init(identity: chrome, members: [("a", { ConstSource(0.1) }), ("b", { ConstSource(0.2) }), ("c", { ConstSource(0.3) })]),
                     "com.spotify.client": .init(identity: spotify, members: [("s", { ConstSource(0.4) })])])
        XCTAssertEqual(e.channels.count, 2)
        XCTAssertEqual(m.memberCount, 4)
        XCTAssertEqual(Set(e.channels.map { $0.name }), ["Google Chrome", "Spotify"])
        let ch = e.channels.first { $0.name == "Google Chrome" }
        XCTAssertEqual(ch?.pid, 100)

        // A tab closes (one member leaves) and another starts: same channel, same fader state.
        ch?.volumeDB = -9
        m.reconcile(["com.google.Chrome": .init(identity: chrome, members: [("b", { ConstSource(0.2) }), ("c", { ConstSource(0.3) }), ("d", { ConstSource(0.5) })]),
                     "com.spotify.client": .init(identity: spotify, members: [("s", { ConstSource(0.4) })])])
        XCTAssertEqual(e.channels.count, 2)
        XCTAssertTrue(e.channels.contains { $0 === ch })                 // the very same channel object
        XCTAssertEqual(ch?.volumeDB ?? 0, -9, accuracy: 0.001)
        XCTAssertEqual(m.memberCount, 4)

        // Spotify's last process ends: its channel goes away.
        m.reconcile(["com.google.Chrome": .init(identity: chrome, members: [("b", { ConstSource(0.2) })])])
        XCTAssertEqual(e.channels.map { $0.name }, ["Google Chrome"])
        m.removeAll()
        XCTAssertEqual(e.channels.count, 0)
    }

    func testChannelRemovedElsewhereIsNeverRemovedTwice() {
        let e = AudioEngine()
        let m = GroupedChannelManager(engine: e)
        let a = ident("a", "App A", pid: 1)
        m.reconcile(["a": .init(identity: a, members: [("x", { ConstSource(0.1) })])])
        let first = e.channels[0]
        e.removeChannel(first)                                           // e.g. the application quit
        // Another channel takes the freed slot.
        let other = e.addChannel(name: "Other", source: ConstSource(0.2))
        XCTAssertEqual(other?.slotIndex, first.slotIndex)
        m.reconcile([:])                                                 // must not touch the slot that now belongs to "Other"
        XCTAssertEqual(e.channels.map { $0.name }, ["Other"])
        // The application comes back: a fresh channel is created.
        m.reconcile(["a": .init(identity: a, members: [("y", { ConstSource(0.1) })])])
        XCTAssertEqual(Set(e.channels.map { $0.name }), ["Other", "App A"])
    }
}
