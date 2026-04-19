# ProxyNaut

ProxyNaut is a modern, high-performance VPN proxy application for iOS, built with **SwiftUI** and powered by the **sing-box** (Libbox) core engine. It provides a seamless and secure networking experience with advanced rule-based routing capabilities.

## 🚀 Key Features

- **Core Engine**: Leverages the power of `sing-box` for superior performance and protocol support.
- **Protocol Support**:
  - Clash YAML/JSON
  - VMess / VLESS
  - ShadowSocks (SS)
  - Trojan
  - Hysteria2 (hy2)
  - TUIC
- **Rule-Based Routing**: Advanced rule engine supporting:
  - Domain (Exact, Suffix, Keyword)
  - IP CIDR
  - Port-based routing
- **Modern UI**: Clean and intuitive interface built entirely with SwiftUI.
- **System Integration**:
  - Uses `NEPacketTunnelProvider` for reliable VPN tunneling.
  - Live Activity support for real-time status updates on the Lock Screen.
- **Import via URL**: Easy subscription management via custom URL scheme (`iosproxy://import?url=...`).

## 🛠 Getting Started

### Prerequisites

- macOS with **Xcode 15.0+**
- **xcodegen** installed (`brew install xcodegen`)
- **pnpm** (if managing web-related dependencies)

### Setup & Build

1. **Clone the repository**:
   ```bash
   git clone https://github.com/xshenf/proxy-naut.git
   cd proxy-naut
   ```

2. **Setup dependencies**:
   Download required frameworks (e.g., `Libbox.xcframework`):

3. **Generate Xcode Project**:
   ```bash
   xcodegen generate
   ```

4. **Open and Build**:
   ```bash
   open ProxyNaut.xcodeproj
   ```
   Select the `ProxyNaut` scheme and run on your physical device or simulator.

## 🏗 Architecture

- **ContainerApp**: The main SwiftUI application containing the dashboard, nodes, rules, and settings.
- **ProxyExtension**: A Network Extension target implementing the `NEPacketTunnelProvider`.
- **ActivityExtension**: Implements Live Activities for Lock Screen status.
- **Shared**: Core logic shared between the app and extensions, including `ProxyManager`, `LibboxManager`, and `SubscriptionManager`.

## 📜 License

This project is licensed under the **GNU General Public License v3.0 (GPLv3)**. See the [LICENSE](LICENSE) file for details.

---

*Made with ❤️ for a better internet.*
