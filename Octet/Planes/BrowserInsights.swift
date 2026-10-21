import Foundation

/// Reads a Browser Control performance recording (the page's own
/// Performance API entries) the way chrome-devtools MCP reports a trace:
/// the metrics, then insights an agent can ask about by name.
enum BrowserInsights {
    static let setID = "NAVIGATION_0"

    static let names = ["DocumentLatency", "LCPBreakdown", "RenderBlocking", "CLSCulprits", "INPBreakdown", "LongTasks",
                        "ThirdParties", "LargestResources", "DOMSize"]

    private static func ms(_ value: Any?) -> String {
        guard let number = value as? Double else { return "n/a" }
        return String(format: "%.0f ms", number)
    }

    private static func rating(_ value: Double?, good: Double, poor: Double) -> String {
        guard let value else { return "" }
        return value <= good ? " (good)" : value <= poor ? " (needs improvement)" : " (poor)"
    }

    static func summary(_ metrics: [String: Any], document: BrowserAgent.NetworkRequest?) -> String {
        let navigation = metrics["navigation"] as? [String: Any] ?? [:]
        let lcp = metrics["lcp"] as? [String: Any]
        let lcpTime = lcp?["time"] as? Double
        let cls = metrics["cls"] as? Double
        let supported = Set(metrics["supported"] as? [String] ?? [])
        var lines = ["## Performance recording of \(metrics["url"] as? String ?? "")",
                     "From the page's Performance APIs in WebKit (no DevTools trace).", "",
                     "### Metrics"]
        lines.append("- TTFB: \(ms(navigation["ttfb"]))" + rating(navigation["ttfb"] as? Double, good: 800, poor: 1800))
        lines.append("- FCP: \(ms(metrics["fcp"]))" + rating(metrics["fcp"] as? Double, good: 1800, poor: 3000))
        if supported.contains("largest-contentful-paint") {
            lines.append("- LCP: \(ms(lcpTime))" + rating(lcpTime, good: 2500, poor: 4000) + ((lcp?["element"] as? String).map { ", element: \($0)" } ?? ""))
        } else {
            lines.append("- LCP: not reported by this WebKit")
        }
        if supported.contains("layout-shift") {
            lines.append(String(format: "- CLS: %.3f", cls ?? 0) + rating(cls, good: 0.1, poor: 0.25))
        } else {
            lines.append("- CLS: not reported by this WebKit")
        }
        lines.append("- DOMContentLoaded: \(ms(navigation["domContentLoaded"])), load: \(ms(navigation["load"]))")
        let resources = metrics["resources"] as? [[String: Any]] ?? []
        lines.append("- Requests: \(resources.count + 1), DOM elements: \(metrics["domSize"] ?? "n/a")")
        if let status = document?.status { lines.append("- Document status: \(status)") }
        lines += ["", "### Available insight sets", "- \(setID): \(metrics["url"] as? String ?? "")",
                  "  Insights: " + names.joined(separator: ", "),
                  "Call performance_analyze_insight with insightSetId \(setID) and one of these for details."]
        return lines.joined(separator: "\n")
    }

    static func analyze(_ metrics: [String: Any], insight: String, network: [BrowserAgent.NetworkRequest]) -> String {
        let navigation = metrics["navigation"] as? [String: Any] ?? [:]
        let resources = (metrics["resources"] as? [[String: Any]] ?? [])
        let pageHost = URL(string: metrics["url"] as? String ?? "")?.host
        var lines = ["## \(insight)"]
        switch insight {
        case "DocumentLatency":
            let document = network.last { $0.resourceType == "document" }
            lines.append("- Redirects: \(ms(navigation["redirect"]))")
            lines.append("- DNS: \(ms(navigation["dns"])), connect: \(ms(navigation["connect"]))")
            lines.append("- Server response (TTFB): \(ms(navigation["ttfb"]))")
            lines.append("- Response end: \(ms(navigation["responseEnd"]))")
            if let transfer = navigation["transfer"] as? Double, transfer > 0 { lines.append("- Transferred: \(Int(transfer)) bytes") }
            if let headers = document?.responseHeaders {
                lines.append("- Compression: \(headers["content-encoding"] ?? "none")")
                lines.append("- Cache-Control: \(headers["cache-control"] ?? "none")")
            }
            if (navigation["ttfb"] as? Double ?? 0) > 600 { lines.append("The server is slow to answer: look at server work, caching, or a CDN.") }
        case "LCPBreakdown":
            guard let lcp = metrics["lcp"] as? [String: Any], let time = lcp["time"] as? Double else {
                lines.append("No LCP entry: this WebKit doesn't report it, or nothing painted yet.")
                break
            }
            let ttfb = navigation["ttfb"] as? Double ?? 0
            lines.append("- LCP: \(ms(time)), element: \(lcp["element"] as? String ?? "unknown")")
            lines.append("- Time to first byte: \(ms(ttfb))")
            if let url = lcp["url"] as? String, !url.isEmpty,
               let resource = resources.first(where: { $0["url"] as? String == url }),
               let start = resource["start"] as? Double, let duration = resource["duration"] as? Double {
                lines.append("- Resource load delay: \(ms(start - ttfb))  (\(url))")
                lines.append("- Resource load duration: \(ms(duration))")
                lines.append("- Element render delay: \(ms(time - start - duration))")
            } else {
                lines.append("- Render delay after TTFB: \(ms(time - ttfb)) (a text element, no resource to load)")
            }
        case "RenderBlocking":
            let fcp = metrics["fcp"] as? Double ?? .infinity
            let blocking = resources.filter {
                ($0["blocking"] as? String) == "blocking"
                    || ($0["blocking"] == nil || $0["blocking"] is NSNull) && ["link", "css", "script"].contains($0["type"] as? String ?? "") && ($0["start"] as? Double ?? .infinity) < fcp
            }
            lines.append(blocking.isEmpty ? "No render-blocking requests found." : "Requests before first paint that can block rendering:")
            for resource in blocking.prefix(20) {
                lines.append("- \(resource["url"] ?? "") (\(resource["type"] ?? ""), \(ms(resource["duration"])))")
            }
        case "CLSCulprits":
            guard let cls = metrics["cls"] as? Double else { lines.append("This WebKit doesn't report layout shifts."); break }
            lines.append(String(format: "CLS %.3f.", cls) + (cls > 0.1 ? " Look for images without width/height, late-loading fonts and content inserted above the fold." : " Nothing to fix."))
        case "INPBreakdown":
            let events = metrics["slowEvents"] as? [[String: Any]] ?? []
            lines.append(events.isEmpty ? "No slow interactions recorded (over 40 ms), or this WebKit doesn't report event timing." : "Slow interactions:")
            for event in events.sorted(by: { ($0["duration"] as? Double ?? 0) > ($1["duration"] as? Double ?? 0) }).prefix(10) {
                lines.append("- \(event["name"] ?? "") at \(ms(event["start"])): \(ms(event["duration"]))")
            }
        case "LongTasks":
            let tasks = metrics["longTasks"] as? [[String: Any]] ?? []
            lines.append(tasks.isEmpty ? "No long tasks recorded, or this WebKit doesn't report them." : "\(tasks.count) long tasks on the main thread:")
            for task in tasks.prefix(15) { lines.append("- at \(ms(task["start"])): \(ms(task["duration"]))") }
        case "ThirdParties":
            var byHost: [String: (count: Int, bytes: Double, time: Double)] = [:]
            for resource in resources {
                guard let host = URL(string: resource["url"] as? String ?? "")?.host, host != pageHost else { continue }
                var entry = byHost[host] ?? (0, 0, 0)
                entry.count += 1
                entry.bytes += resource["transfer"] as? Double ?? 0
                entry.time += resource["duration"] as? Double ?? 0
                byHost[host] = entry
            }
            lines.append(byHost.isEmpty ? "No third-party requests." : "Third-party hosts by bytes transferred:")
            for (host, entry) in byHost.sorted(by: { $0.value.bytes > $1.value.bytes }).prefix(15) {
                lines.append("- \(host): \(entry.count) requests, \(Int(entry.bytes)) bytes, \(ms(entry.time)) total")
            }
        case "LargestResources":
            for resource in resources.sorted(by: { ($0["transfer"] as? Double ?? 0) > ($1["transfer"] as? Double ?? 0) }).prefix(15) {
                lines.append("- \(Int(resource["transfer"] as? Double ?? 0)) bytes (\(Int(resource["encoded"] as? Double ?? 0)) encoded) \(resource["url"] ?? "")")
            }
            if resources.isEmpty { lines.append("No resources recorded.") }
            lines.append("(Cross-origin resources without Timing-Allow-Origin report 0 bytes.)")
        case "DOMSize":
            let size = metrics["domSize"] as? Int ?? 0
            lines.append("\(size) elements." + (size > 1400 ? " Over Lighthouse's 1,400: large DOMs slow style, layout and interactions." : ""))
        default:
            lines.append("Unknown insight. Use one of: " + names.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }
}
