import BunnyGridCore
import SwiftUI

/// Redis Sentinel: with a master name, Host/Port name a sentinel (6379 is read as 26379) and the driver connects
/// to the master it reports. A Redis Cluster needs no setting: it is detected when connecting.
struct RedisSentinelRows: View {
    @Binding var config: ConnectionConfig

    private var options: Binding<RedisOptions> {
        Binding(get: { config.redis ?? RedisOptions() }, set: { config.redis = $0.usesSentinel || !$0.sentinels.isEmpty ? $0 : nil })
    }

    var body: some View {
        GridRow {
            Text("Sentinel Master").gridColumnAlignment(.trailing)
            TextField("", text: options.sentinelMaster, prompt: Text("optional (e.g. mymaster)"))
        }
        if options.wrappedValue.usesSentinel {
            GridRow {
                Text("More Sentinels").gridColumnAlignment(.trailing)
                TextField("", text: Binding(get: { options.wrappedValue.sentinels.joined(separator: ", ") }, set: {
                    options.wrappedValue.sentinels = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }), prompt: Text("host2:26379, host3:26379"))
            }
        }
    }
}
