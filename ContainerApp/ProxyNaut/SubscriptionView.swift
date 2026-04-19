import SwiftUI

struct SubscriptionView: View {
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @State private var showingAddSubscription = false
    @State private var subscriptionToEdit: Subscription?
    @State private var isRefreshing = false
    
    var body: some View {
        NavigationStack {
            List {
                if subscriptionManager.subscriptions.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "link.circle")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text(LocalizationManager.string("sub.empty_title"))
                            .font(.headline)
                        Text(LocalizationManager.string("sub.empty_desc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(subscriptionManager.subscriptions) { subscription in
                        SubscriptionRowView(subscription: subscription) {
                            subscriptionToEdit = subscription
                        } onSelect: {
                            if subscriptionManager.selectedSubscriptionId == subscription.id {
                                subscriptionManager.deselectSubscription()
                            } else {
                                subscriptionManager.selectSubscription(subscription)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                subscriptionToEdit = subscription
                            } label: {
                                Label(LocalizationManager.string("sub.edit"), systemImage: "pencil")
                            }
                            .tint(.orange)
                            
                            Button {
                                Task {
                                    isRefreshing = true
                                    await subscriptionManager.fetchAndUpdate(subscription)
                                    isRefreshing = false
                                }
                            } label: {
                                Label(LocalizationManager.string("sub.refresh"), systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                        }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    subscriptionManager.removeSubscription(subscription)
                                } label: {
                                    Label(LocalizationManager.string("sub.delete"), systemImage: "trash")
                                }
                            }

                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            isRefreshing = true
                            subscriptionManager.fetchAll()
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            isRefreshing = false
                        }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingAddSubscription = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSubscription) {
                AddSubscriptionSheetView()
            }
            .sheet(item: $subscriptionToEdit) { subscription in
                EditSubscriptionSheetView(subscription: subscription)
            }
        }
    }
}

struct SubscriptionRowView: View {
    let subscription: Subscription
    let onEdit: () -> Void
    let onSelect: () -> Void
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    var isSelected: Bool {
        subscriptionManager.selectedSubscriptionId == subscription.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .gray)
                    .font(.title2)

                Text(subscription.name)
                    .font(.headline)

                Spacer()

                if isSelected {
                    Text(LocalizationManager.string("sub.active"))
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue)
                        .cornerRadius(12)
                }
            }

            HStack {
                Text(subscription.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                Text("\(subscription.nodes.count) nodes")
                    .font(.caption)
                    .foregroundColor(.blue)
            }

            if let lastUpdate = subscription.lastUpdate {
                HStack(spacing: 4) {
                    Text(LocalizationManager.string("sub.updated_at"))
                    Text(lastUpdate, style: .relative)
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 40)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .overlay(alignment: .trailing) {
            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.title3)
                    .foregroundColor(.blue)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
    }
}

struct AddSubscriptionSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var autoUpdate: Bool = true
    @State private var updateInterval: Subscription.UpdateInterval = .daily
    @State private var showingScanner = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section(LocalizationManager.sectionSubscriptionInfo) {
                    TextField(LocalizationManager.labelName, text: $name)
                    TextField(LocalizationManager.labelURL, text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                }
                
                Section {
                    Button {
                        showingScanner = true
                    } label: {
                        Label(LocalizationManager.labelScanQRCode, systemImage: "qrcode.viewfinder")
                    }
                    
                    Toggle(LocalizationManager.labelAutoUpdate, isOn: $autoUpdate)
                    
                    if autoUpdate {
                        Picker(LocalizationManager.string("rule.update_interval"), selection: $updateInterval) {
                            ForEach(Subscription.UpdateInterval.allCases, id: \.self) { interval in
                                Text(LocalizationManager.string("update_interval.\(interval.rawValue.lowercased())")).tag(interval)
                            }
                        }
                    }
                }
            }
            .navigationTitle(LocalizationManager.navAddSubscription)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizationManager.string("button.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationManager.string("button.add")) {
                        let subscription = Subscription(
                            name: name,
                            url: url,
                            autoUpdate: autoUpdate,
                            updateInterval: updateInterval
                        )
                        subscriptionManager.addSubscription(subscription)
                        Task {
                            await subscriptionManager.fetchAndUpdate(subscription)
                        }
                        dismiss()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerView { code in
                    handleScannedCode(code)
                }
            }
        }
    }
    
    private func handleScannedCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.main.async {
            if trimmed.hasPrefix("vmess://") || trimmed.hasPrefix("ss://") || trimmed.hasPrefix("trojan://") ||
               trimmed.hasPrefix("vless://") || trimmed.hasPrefix("hysteria2://") ||
               trimmed.hasPrefix("hy2://") || trimmed.hasPrefix("tuic://") {
                self.url = trimmed
                if self.name.isEmpty {
                    self.name = "Scanned Node"
                }
            } else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                self.url = trimmed
                if self.name.isEmpty {
                    self.name = "Scanned Subscription"
                }
            } else {
                self.url = trimmed
                if self.name.isEmpty {
                    self.name = "Scanned Config"
                }
            }

            self.showingScanner = false
        }
    }
}

struct EditSubscriptionSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    
    let subscription: Subscription
    @State private var name: String
    @State private var url: String
    @State private var autoUpdate: Bool
    @State private var updateInterval: Subscription.UpdateInterval
    
    init(subscription: Subscription) {
        self.subscription = subscription
        _name = State(initialValue: subscription.name)
        _url = State(initialValue: subscription.url)
        _autoUpdate = State(initialValue: subscription.autoUpdate)
        _updateInterval = State(initialValue: subscription.updateInterval)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(LocalizationManager.sectionInformation) {
                    TextField(LocalizationManager.labelName, text: $name)
                    TextField(LocalizationManager.labelURL, text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                }
                
                Section(LocalizationManager.sectionAutoUpdate) {
                    Toggle(LocalizationManager.labelEnableAutoUpdate, isOn: $autoUpdate)
                    
                    if autoUpdate {
                        Picker(LocalizationManager.string("rule.update_interval"), selection: $updateInterval) {
                            ForEach(Subscription.UpdateInterval.allCases, id: \.self) { interval in
                                Text(LocalizationManager.string("update_interval.\(interval.rawValue.lowercased())")).tag(interval)
                            }
                        }
                    }
                }
                
                Section {
                    Button(role: .destructive) {
                        subscriptionManager.removeSubscription(subscription)
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text(LocalizationManager.string("sub.delete_button"))
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(LocalizationManager.string("sub.nav_edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizationManager.string("button.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationManager.string("button.save")) {
                        var updated = subscription
                        updated.name = name
                        updated.url = url
                        updated.autoUpdate = autoUpdate
                        updated.updateInterval = updateInterval
                        subscriptionManager.updateSubscription(updated)
                        Task {
                            await subscriptionManager.fetchAndUpdate(updated)
                        }
                        dismiss()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }
}
