import CoreServices
import Foundation

/// Calls `onChange` (debounced by FSEvents latency) when anything under `path` changes.
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let box: Unmanaged<Box>

    private final class Box {
        let onChange: () -> Void
        init(_ f: @escaping () -> Void) { onChange = f }
    }

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        box = Unmanaged.passRetained(Box { DispatchQueue.main.async { MainActor.assumeIsolated(onChange) } })
        var ctx = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     0.3, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        box.release()
    }
}
