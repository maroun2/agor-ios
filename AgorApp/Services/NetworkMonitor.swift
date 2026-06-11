import Network
import Foundation

@Observable
final class NetworkMonitor {
    private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.agor.NetworkMonitor", qos: .utility)

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard self?.isOnline != online else { return }
                self?.isOnline = online
                AppLogger.shared.log(
                    online ? "[Network] connectivity restored" : "[Network] connectivity lost",
                    level: online ? .info : .warning,
                    category: "Network"
                )
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
