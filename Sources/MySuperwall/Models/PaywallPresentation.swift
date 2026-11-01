import Foundation

public struct PaywallPresentation: Codable, Equatable {
    public var style: String = "system"
    public var durationMs: Int = 280
    public var curve: String = "easeOutCubic"
    public var dismissable: Bool = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case style,durationMs,curve,dismissable }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? c.decode(String.self,forKey: .style)) ?? "system"
        durationMs = min(4000,max(0,(try? c.decode(Int.self,forKey: .durationMs)) ?? 280))
        curve = (try? c.decode(String.self,forKey: .curve)) ?? "easeOutCubic"
        dismissable = (try? c.decode(Bool.self,forKey: .dismissable)) ?? true
    }
}
