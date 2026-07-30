import Foundation
import MetricKit

final class HorizonMetricKitObserver: NSObject, MXMetricManagerSubscriber {
    static let shared = HorizonMetricKitObserver()

    private var isStarted = false

    private override init() {
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        MXMetricManager.shared.add(self)
        HorizonDebugLog.shared.log("metrickit.start")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            HorizonDebugLog.shared.log("metrickit.metrics", fields: payloadSummary(payload))
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            HorizonDebugLog.shared.log("metrickit.diagnostics", fields: payloadSummary(payload))
        }
    }

    private func payloadSummary(_ payload: MXMetricPayload) -> [String: Any] {
        var fields: [String: Any] = [
            "payloadClass": String(describing: type(of: payload))
        ]

        let data = payload.jsonRepresentation()
        if !data.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            fields["topLevelKeys"] = object.keys.sorted().joined(separator: ",")
            fields["bytes"] = data.count
        }

        return fields
    }

    private func payloadSummary(_ payload: MXDiagnosticPayload) -> [String: Any] {
        var fields: [String: Any] = [
            "payloadClass": String(describing: type(of: payload))
        ]

        let data = payload.jsonRepresentation()
        if !data.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            fields["topLevelKeys"] = object.keys.sorted().joined(separator: ",")
            fields["bytes"] = data.count
        }

        return fields
    }
}
