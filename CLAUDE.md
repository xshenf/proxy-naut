# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

iOS VPN proxy application built with SwiftUI, using Network Extension framework (NEPacketTunnelProvider) and sing-box (Libbox) as the core proxy engine.

## Build Commands

```bash
# Setup dependencies (download Libbox.xcframework)
bash scripts/setup_libs.sh

# Regenerate Xcode project (after modifying project.yml)
xcodegen generate

# Open in Xcode
open iOSProxyApp.xcodeproj
```

## Architecture

- **ContainerApp**: Main SwiftUI app (nodes, subscriptions, rules, logs, settings)
- **ProxyExtension**: NEPacketTunnelProvider for VPN tunnel
- **ActivityExtension**: Live Activity for Lock Screen status
- **Shared**: Core logic shared between app and extension (ProxyManager, LibboxManager, RuleEngine, SubscriptionManager, etc.)
- **Frameworks/Libbox.xcframework**: sing-box Go library

Configuration and node data shared via App Group (`group.com.proxynaut`).

## Key Details

- iOS 16.1+ deployment target
- Swift 5.0, SwiftUI
- URL Scheme: `iosproxy://import?url=...` for importing subscriptions
- Default proxy listen port: 1081
- Command server port: 64500 (TCP, due to iOS socket path length limits)
- App Group: `group.com.proxynaut`
- Bundle ID prefix: `com.proxynaut`

## VPN Tunnel Flow

1. `PacketTunnelProvider.startTunnel()` loads config and selected node
2. `LibboxManager.start()` initializes sing-box
3. `AppPlatformInterface.openTun()` creates socket pair for packet I/O
4. Two async tasks forward packets between `packetFlow` and Libbox
5. `LibboxManager.stop()` closes service on stop

## Rule Engine

Supports: domain exact match, domain suffix, domain keyword, IP CIDR, port-based routing, and final default action.

## Subscription Formats

Clash YAML, JSON, vmess://, ss://, trojan://, vless://, hysteria2:// (hy2://), tuic:// links.