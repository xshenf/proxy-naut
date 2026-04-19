import Foundation

public class GeoIPDatabase {
    public static let shared = GeoIPDatabase()
    
    private var v4Ranges: [IPRangeV4] = []
    private var v6Ranges: [IPRangeV6] = []
    private var isLoaded = false
    
    private struct IPRangeV4 {
        let start: UInt32
        let end: UInt32
    }
    
    private struct IPRangeV6 {
        let start: UInt128
        let end: UInt128
    }
    
    private init() {
        loadData()
    }
    
    private func loadData() {
        if isLoaded { return }
        
        let v4B64 = Self.v4FullData
        let v6B64 = Self.v6FullData
        
        if !v4B64.isEmpty, let v4Data = Data(base64Encoded: v4B64, options: .ignoreUnknownCharacters) {
            v4Ranges = parseV4Ranges(v4Data)
        }
        
        if !v6B64.isEmpty, let v6Data = Data(base64Encoded: v6B64, options: .ignoreUnknownCharacters) {
            v6Ranges = parseV6Ranges(v6Data)
        }
        
        if v4Ranges.isEmpty {
            v4Ranges = [
                IPRangeV4(start: 0x01000100, end: 0x010001FF),
                IPRangeV4(start: 0x01000800, end: 0x01000FFF),
                IPRangeV4(start: 0x7F000000, end: 0x81FFFFFF),
            ]
        }
        
        v4Ranges.sort { $0.start < $1.start }
        v6Ranges.sort { $0.start < $1.start }
        
        isLoaded = true
    }
    
    public func lookup(_ ip: String) -> String? {
        if ip.contains(":") {
            guard let ipValue = ipToUInt128(ip) else { return nil }
            return isInChinaV6(ipValue) ? "CN" : nil
        } else {
            guard let ipValue = ipToUInt32(ip) else { return nil }
            return isInChinaV4(ipValue) ? "CN" : nil
        }
    }
    
    private func isInChinaV4(_ ip: UInt32) -> Bool {
        var low = 0
        var high = v4Ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = v4Ranges[mid]
            if ip < range.start { high = mid - 1 }
            else if ip > range.end { low = mid + 1 }
            else { return true }
        }
        return false
    }
    
    private func isInChinaV6(_ ip: UInt128) -> Bool {
        var low = 0
        var high = v6Ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = v6Ranges[mid]
            if ip < range.start { high = mid - 1 }
            else if ip > range.end { low = mid + 1 }
            else { return true }
        }
        return false
    }
    
    private func ipToUInt32(_ ip: String) -> UInt32? {
        var addr = in_addr()
        if inet_pton(AF_INET, ip, &addr) == 1 {
            return UInt32(bigEndian: addr.s_addr)
        }
        return nil
    }
    
    private func ipToUInt128(_ ip: String) -> UInt128? {
        var addr = in6_addr()
        if inet_pton(AF_INET6, ip, &addr) == 1 {
            return UInt128(addr)
        }
        return nil
    }
    
    private func parseV4Ranges(_ data: Data) -> [IPRangeV4] {
        var ranges: [IPRangeV4] = []
        let count = data.count / 8
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
            for i in 0..<count {
                ranges.append(IPRangeV4(start: UInt32(bigEndian: base[i*2]), end: UInt32(bigEndian: base[i*2+1])))
            }
        }
        return ranges
    }
    
    private func parseV6Ranges(_ data: Data) -> [IPRangeV6] {
        var ranges: [IPRangeV6] = []
        let count = data.count / 32
        for i in 0..<count {
            let start = UInt128(data.subdata(in: i*32..<i*32+16))
            let end = UInt128(data.subdata(in: i*32+16..<i*32+32))
            ranges.append(IPRangeV6(start: start, end: end))
        }
        return ranges
    }
}

public struct UInt128: Comparable, Equatable {
    public let hi: UInt64
    public let lo: UInt64
    
    public init(_ data: Data) {
        let hiData = data.prefix(8)
        let loData = data.suffix(8)
        self.hi = hiData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        self.lo = loData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    }
    
    public init(_ addr: in6_addr) {
        var temp = addr
        let data = withUnsafeBytes(of: &temp) { Data($0) }
        self.init(data)
    }
    
    public static func < (lhs: UInt128, rhs: UInt128) -> Bool {
        if lhs.hi != rhs.hi { return lhs.hi < rhs.hi }
        return lhs.lo < rhs.lo
    }
}
