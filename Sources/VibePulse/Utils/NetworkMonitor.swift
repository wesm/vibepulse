import Foundation
import Network

enum NetworkMonitor {
    static func isOnline(timeout: TimeInterval = 0.3) -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "VibePulse.NetworkMonitor")
        let semaphore = DispatchSemaphore(value: 0)
        var status: NWPath.Status?

        monitor.pathUpdateHandler = { path in
            status = path.status
            semaphore.signal()
            monitor.cancel()
        }

        monitor.start(queue: queue)

        let result = semaphore.wait(timeout: .now() + timeout)
        if result == .timedOut {
            monitor.cancel()
            return true
        }

        return status == .satisfied
    }
}
