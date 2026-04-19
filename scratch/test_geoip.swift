import Foundation

@main
struct TestApp {
    static func main() {
        let db = GeoIPDatabase.shared
        let ip = "101.91.134.17"
        let result = db.lookup(ip)
        print("Lookup \(ip): \(result ?? "NOT FOUND")")

        let ip6 = "240e:e1:aa00:4000::1c"
        let result6 = db.lookup(ip6)
        print("Lookup \(ip6): \(result6 ?? "NOT FOUND")")
    }
}
