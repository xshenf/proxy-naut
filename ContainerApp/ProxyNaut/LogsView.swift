import SwiftUI

enum RouteFilter: String, CaseIterable {
    case all = "All"
    case direct = "Direct"
    case proxy = "Proxy"
    case reject = "Reject"
}

struct LogsView: View {
    @ObservedObject private var logManager = LogManager.shared
    @State private var searchText: String = ""
    @State private var autoScroll: Bool = true
    @State private var selectedRouteFilter: RouteFilter = .all
    @State private var onlyErrors: Bool = false
    @State private var refreshTimer: Timer? = nil

    var filteredLogs: [LogEntry] {
        logManager.logs.filter { log in
            let msg = log.message.lowercased()

            // 路由筛选
            let matchesRoute: Bool = {
                switch selectedRouteFilter {
                case .all: return true
                case .direct: return msg.contains("[direct]")
                case .proxy: return msg.contains("[proxy]")
                case .reject: return msg.contains("[block]")
                }
            }()

            // 仅错误
            let matchesError = !onlyErrors || log.level == .error

            // 搜索
            let matchesSearch = searchText.isEmpty || log.message.localizedCaseInsensitiveContains(searchText)

            return matchesRoute && matchesError && matchesSearch
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索栏
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField(LocalizationManager.labelSearch, text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color(.systemGray5).opacity(0.5))

                // 筛选 chip 栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RouteFilter.allCases, id: \.self) { filter in
                            Button {
                                selectedRouteFilter = filter
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: chipIcon(filter))
                                        .font(.system(size: 10))
                                    Text(filter.rawValue)
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(selectedRouteFilter == filter ? chipColor(filter) : Color(.systemGray5))
                                .foregroundColor(selectedRouteFilter == filter ? .white : .primary)
                                .cornerRadius(14)
                            }
                        }

                        Divider().frame(height: 20)

                        Button {
                            onlyErrors.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 10))
                                Text("Error")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(onlyErrors ? Color.red : Color(.systemGray5))
                            .foregroundColor(onlyErrors ? .white : .primary)
                            .cornerRadius(14)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }

                // 日志列表
                ScrollViewReader { proxy in
                    List {
                        if filteredLogs.isEmpty {
                            ContentUnavailableView(LocalizationManager.emptyNoLogs, systemImage: "doc.text.magnifyingglass", description: Text(LocalizationManager.emptyNoLogsDesc))
                        } else {
                            ForEach(filteredLogs) { log in
                                LogRowView(log: log)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                    .id(log.id)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: filteredLogs.count) { _ in
                        if autoScroll, let lastLog = filteredLogs.last {
                            proxy.scrollTo(lastLog.id, anchor: .bottom)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        autoScroll.toggle()
                    } label: {
                        Image(systemName: autoScroll ? "arrow.down.to.line" : "arrow.down.to.line.compact")
                            .foregroundColor(autoScroll ? .blue : .secondary)
                    }

                    Button(role: .destructive) {
                        logManager.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .onAppear {
                refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                    logManager.reloadLogsFromServer()
                }
            }
            .onDisappear {
                refreshTimer?.invalidate()
                refreshTimer = nil
            }
        }
    }

    private func chipIcon(_ filter: RouteFilter) -> String {
        switch filter {
        case .all: return "list.bullet"
        case .direct: return "arrow.right.circle"
        case .proxy: return "arrow.triangle.turn.up.right.circle"
        case .reject: return "xmark.circle"
        }
    }

    private func chipColor(_ filter: RouteFilter) -> Color {
        switch filter {
        case .all: return .blue
        case .direct: return .green
        case .proxy: return .purple
        case .reject: return .red
        }
    }
}

struct LogRowView: View {
    let log: LogEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(log.timestamp, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let tag = routeTag {
                    Text(tag.0)
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(tag.1)
                        .cornerRadius(3)
                } else if log.level == .error {
                    Text("ERROR")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red)
                        .cornerRadius(3)
                }

                if let source = log.source {
                    Text(source)
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .opacity(0.8)
                }
            }

            Text(log.message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(log.level == .error ? .red :
                                 log.message.contains("[direct]") ? .secondary : .primary)
                .lineLimit(nil)
        }
        .padding(.vertical, 6)
    }

    private var routeTag: (String, Color)? {
        let msg = log.message.lowercased()
        if msg.contains("[proxy]") { return ("PROXY", .purple) }
        if msg.contains("[direct]") { return ("DIRECT", .green) }
        if msg.contains("[block]") { return ("REJECT", .red) }
        return nil
    }
}
