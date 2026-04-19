import Foundation
import Libbox

func testParsing() {
    let clashConfig = """
    proxies:
      - name: "Test Node"
        type: vmess
        server: 1.2.3.4
        port: 443
        uuid: some-uuid
        alterId: 0
        cipher: auto
        network: ws
        ws-opts:
          path: /
    """
    
    var error: NSError?
    // 尝试使用内核的 FormatConfig 来转换格式（通常会转为 JSON）
    if let result = LibboxFormatConfig(clashConfig, &error) {
        print("Success: \(result.value)")
    } else {
        print("Failed: \(error?.localizedDescription ?? "unknown error")")
    }
}

testParsing()
