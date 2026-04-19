import SwiftUI

struct RulesView: View {
    @StateObject private var ruleSubManager = RuleSubscriptionManager.shared
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @State private var rules: [ProxyRule] = []
    @State private var showingAddRule = false
    @State private var editingRule: ProxyRule?
    @State private var showingSubscriptions = false
    @State private var showingAddSubscription = false
    @State private var selectedTab: RuleTab = .manual

    enum RuleTab {
        case manual, subscriptions
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab Picker
                Picker(LocalizationManager.string("section.rule_source"), selection: $selectedTab) {
                    Text(LocalizationManager.string("rules.tab.manual")).tag(RuleTab.manual)
                    Text(LocalizationManager.string("rules.tab.subscriptions")).tag(RuleTab.subscriptions)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == .manual {
                    manualRulesView
                } else {
                    subscriptionRulesView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectedTab == .manual {
                        Button {
                            showingAddRule = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    } else {
                        Button {
                            showingAddSubscription = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddRule) {
                AddRuleView { newRule in
                    rules.append(newRule)
                    saveManualRules()
                }
            }
            .sheet(item: $editingRule) { rule in
                EditRuleView(rule: rule) { updatedRule in
                    if let index = rules.firstIndex(where: { $0.id == updatedRule.id }) {
                        rules[index] = updatedRule
                        saveManualRules()
                    }
                }
            }
            .sheet(isPresented: $showingAddSubscription) {
                AddRuleSubscriptionView()
            }
            .onAppear {
                loadRules()
            }
        }
    }

    // MARK: - Manual Rules View

    private var manualRulesView: some View {
        List {
            Section {
                HStack {
                    Toggle(isOn: Binding(
                        get: { Configuration.shared.getAppConfiguration().useBuiltInRules },
                        set: { newVal in 
                            var config = Configuration.shared.load()
                            config.useBuiltInRules = newVal
                            Configuration.shared.save(config)
                        }
                    )) {
                        NavigationLink(destination: BaseRulesetView()) {
                            Label(LocalizationManager.string("ruleset.base_title"), systemImage: "shield.checkered")
                                .fontWeight(.medium)
                        }
                    }
                }
            } header: {
                Text(LocalizationManager.string("section.smart_packages"))
            } footer: {
                Text(LocalizationManager.string("ruleset.base_desc"))
            }

            Section(LocalizationManager.string("section.manual_rules")) {
                if rules.isEmpty {
                    Text(LocalizationManager.string("empty.no_rules"))
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(rules.indices, id: \.self) { index in
                        RuleRowView(rule: rules[index])
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    rules.remove(at: index)
                                    saveManualRules()
                                } label: {
                                    Label(LocalizationManager.string("rule.delete"), systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    editingRule = rules[index]
                                } label: {
                                    Label(LocalizationManager.string("rule.edit"), systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                    }
                }
            }
            
            Section {
                Button(action: {
                    rules = []
                    saveManualRules()
                }) {
                    Label(LocalizationManager.string("rule.clear_all"), systemImage: "trash")
                        .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Subscription Rules View

    private var subscriptionRulesView: some View {
        List {
            // Refresh Button
            Section {
                HStack {
                    Button(action: {
                        Task {
                            await ruleSubManager.fetchAll()
                            ruleSubManager.reloadAllRules()
                        }
                    }) {
                        Label(LocalizationManager.string("rule.refresh_all"), systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(ruleSubManager.isLoading)
                }
                .padding(.vertical, 4)
            }

            // Custom rule subscriptions (ad-block / filter lists)
            Section(LocalizationManager.string("rules.section.custom_subs")) {
                ForEach(ruleSubManager.subscriptions) { sub in
                    RuleSubscriptionRowView(subscription: sub)
                }
            }

            // Rules that came bundled with node subscriptions (Clash YAML `rules:`)
            Section {
                if subscriptionManager.subscriptions.isEmpty {
                    Text(LocalizationManager.string("rules.node_subs.empty"))
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(subscriptionManager.subscriptions) { sub in
                        NodeSubscriptionRulesRow(subscription: sub)
                    }
                }
            } header: {
                Text(LocalizationManager.string("rules.section.node_subs"))
            } footer: {
                Text(LocalizationManager.string("rules.node_subs.footer"))
            }

            // Total rule count across ad-block subscriptions
            Section {
                HStack {
                    Text(LocalizationManager.string("label.total_rules"))
                    Spacer()
                    Text("\(ruleSubManager.subscriptions.reduce(0) { $0 + $1.ruleCount })")
                        .foregroundColor(.secondary)
                }
            }
        }
        .overlay {
            if ruleSubManager.isLoading {
                ProgressView(LocalizationManager.string("empty.fetching"))
            }
        }
    }

    private func saveManualRules() {
        var config = Configuration.shared.load()
        config.rules = rules
        Configuration.shared.save(config)
    }

    private func loadRules() {
        let config = Configuration.shared.load()
        rules = config.rules
    }
}

struct RuleRowView: View {
    let rule: ProxyRule
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.pattern)
                    .font(.body)
                HStack(spacing: 8) {
                    Text(LocalizationManager.string("rule_type.\(rule.type.rawValue)"))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(4)
                    
                    Text(LocalizationManager.string("action.\(rule.action.rawValue)"))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(actionColor.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            Spacer()
        }
    }
    
    private var actionColor: Color {
        switch rule.action {
        case .direct: return .green
        case .proxy: return .blue
        case .reject: return .red
        }
    }
}

struct AddRuleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pattern: String = ""
    @State private var selectedType: ProxyRule.RuleType = .domain
    @State private var selectedAction: ProxyRule.RuleAction = .proxy
    let onSave: (ProxyRule) -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section(LocalizationManager.string("label.pattern")) {
                    TextField(LocalizationManager.string("placeholder.domain_ip_cidr"), text: $pattern)
                }
                
                Section(LocalizationManager.string("label.rule_type")) {
                    Picker(LocalizationManager.string("label.rule_type"), selection: $selectedType) {
                        ForEach(ProxyRule.RuleType.allCases, id: \.self) { type in
                            Text(LocalizationManager.string("rule_type.\(type.rawValue)")).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                }
                
                Section(LocalizationManager.string("label.action")) {
                    Picker(LocalizationManager.string("label.action"), selection: $selectedAction) {
                        Text(LocalizationManager.string("action.direct")).tag(ProxyRule.RuleAction.direct)
                        Text(LocalizationManager.string("action.proxy")).tag(ProxyRule.RuleAction.proxy)
                        Text(LocalizationManager.string("action.reject")).tag(ProxyRule.RuleAction.reject)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(LocalizationManager.string("rule.add_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizationManager.string("rule.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationManager.string("rule.save")) {
                        let rule = ProxyRule(type: selectedType, pattern: pattern, action: selectedAction)
                        onSave(rule)
                        dismiss()
                    }
                    .disabled(pattern.isEmpty)
                }
            }
        }
    }
}

struct EditRuleView: View {
    @Environment(\.dismiss) private var dismiss
    let rule: ProxyRule
    let onSave: (ProxyRule) -> Void
    
    @State private var pattern: String = ""
    @State private var selectedType: ProxyRule.RuleType = .domain
    @State private var selectedAction: ProxyRule.RuleAction = .proxy
    
    var body: some View {
        NavigationStack {
            Form {
                Section(LocalizationManager.string("label.pattern")) {
                    TextField(LocalizationManager.string("placeholder.domain_ip_cidr"), text: $pattern)
                }
                
                Section(LocalizationManager.string("label.rule_type")) {
                    Picker(LocalizationManager.string("label.rule_type"), selection: $selectedType) {
                        ForEach(ProxyRule.RuleType.allCases, id: \.self) { type in
                            Text(LocalizationManager.string("rule_type.\(type.rawValue)")).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                }
                
                Section(LocalizationManager.string("label.action")) {
                    Picker(LocalizationManager.string("label.action"), selection: $selectedAction) {
                        Text(LocalizationManager.string("action.direct")).tag(ProxyRule.RuleAction.direct)
                        Text(LocalizationManager.string("action.proxy")).tag(ProxyRule.RuleAction.proxy)
                        Text(LocalizationManager.string("action.reject")).tag(ProxyRule.RuleAction.reject)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(LocalizationManager.string("rule.edit_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizationManager.string("rule.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationManager.string("rule.save")) {
                        var updatedRule = rule
                        updatedRule.pattern = pattern
                        updatedRule.type = selectedType
                        updatedRule.action = selectedAction
                        onSave(updatedRule)
                        dismiss()
                    }
                }
            }
            .onAppear {
                pattern = rule.pattern
                selectedType = rule.type
                selectedAction = rule.action
            }
        }
    }
}

// MARK: - Rule Subscription Row

struct RuleSubscriptionRowView: View {
    @ObservedObject var manager = RuleSubscriptionManager.shared
    let subscription: RuleSubscription
    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(subscription.name)
                            .font(.body)
                            .fontWeight(.medium)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { subscription.enabled },
                            set: { _ in manager.toggleEnabled(subscription) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    HStack(spacing: 12) {
                        Label(subscription.statusText, systemImage: subscription.enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(subscription.enabled ? .green : .secondary)

                        Spacer()

                        if subscription.ruleCount > 0 {
                        Text("\(subscription.ruleCount) \(LocalizationManager.string("rule.rules_count"))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let lastUpdate = subscription.lastUpdate {
                    HStack(spacing: 4) {
                        Text(LocalizationManager.string("rule.last_updated"))
                        Text(lastUpdate, style: .relative)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            showingDetail = true
        }
        .sheet(isPresented: $showingDetail) {
            RuleSubscriptionDetailView(subscription: subscription)
        }
    }
}

// MARK: - Add Rule Subscription View

struct AddRuleSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager = RuleSubscriptionManager.shared
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var autoUpdate: Bool = true
    @State private var updateInterval: RuleSubscription.UpdateInterval = .weekly

    // Popular presets for quick selection
    private var popularRules: [(name: String, url: String)] {
        [
            (LocalizationManager.string("popular.gfwlist"), "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt"),
            (LocalizationManager.string("popular.china_domains"), "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/direct.txt"),
            (LocalizationManager.string("popular.anti_ad"), "https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-clash.yaml"),
            ("AdGuard DNS Filter", "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"),
            ("REIJI AdBlock", "https://raw.githubusercontent.com/REIJI007/AdBlock_Rule_For_Clash/main/adblock_reject.yaml"),
            ("StevenBlack HOSTS", "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"),
            ("EasyList China", "https://easylist-downloads.adblockplus.org/easylistchina.txt"),
            ("AdGuard Base Filter", "https://raw.githubusercontent.com/AdguardTeam/AdguardFilters/master/BaseFilter/sections/adservers.txt"),
        ]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(LocalizationManager.string("rule.section_custom")) {
                    TextField(LocalizationManager.string("rule.name_placeholder"), text: $name)
                    TextField(LocalizationManager.string("rule.url_placeholder"), text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section(LocalizationManager.string("rule.section_options")) {
                    Toggle(LocalizationManager.string("rule.auto_update"), isOn: $autoUpdate)
                    if autoUpdate {
                    Picker(LocalizationManager.string("rule.update_interval"), selection: $updateInterval) {
                        ForEach(RuleSubscription.UpdateInterval.allCases, id: \.self) { interval in
                            Text(LocalizationManager.string("update_interval.\(interval.rawValue.lowercased())")).tag(interval)
                        }
                    }
                    }
                }

                Section(LocalizationManager.string("rule.section_popular")) {
                    ForEach(popularRules, id: \.url) { rule in
                        Button(action: {
                            name = rule.name
                            url = rule.url
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.name)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text(rule.url)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle(LocalizationManager.string("rule.add_subscription_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizationManager.string("rule.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationManager.string("rule.add_button")) {
                        let sub = RuleSubscription(
                            name: name.isEmpty ? LocalizationManager.string("rule.custom_rule_default") : name,
                            url: url,
                            enabled: true,
                            autoUpdate: autoUpdate,
                            updateInterval: updateInterval
                        )
                        manager.addSubscription(sub)
                        dismiss()
                    }
                    .disabled(url.isEmpty || !url.lowercased().hasPrefix("http"))
                }
            }
        }
    }
}

// MARK: - Rule Subscription Detail View

struct RuleSubscriptionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager = RuleSubscriptionManager.shared
    let subscription: RuleSubscription

    var body: some View {
        NavigationStack {
            Form {
                Section(LocalizationManager.string("rule.detail_info")) {
                    LabeledContent(LocalizationManager.string("rule.detail_name"), value: subscription.name)
                    LabeledContent(LocalizationManager.string("rule.detail_rules"), value: "\(subscription.ruleCount)")
                    if let lastUpdate = subscription.lastUpdate {
                        LabeledContent(LocalizationManager.string("rule.detail_last_update"), value: lastUpdate, format: .dateTime)
                    }
                    LabeledContent(LocalizationManager.string("rule.auto_update"), value: subscription.autoUpdate ? subscription.updateInterval.rawValue : LocalizationManager.string("rule.detail_manual"))
                }

                Section(LocalizationManager.string("rule.detail_url")) {
                    Text(subscription.url)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Section {
                    Button(role: .destructive) {
                        manager.removeSubscription(subscription)
                        dismiss()
                    } label: {
                        Label(LocalizationManager.string("rule.detail_remove"), systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle(subscription.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationManager.string("rule.detail_done")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

extension ProxyRule: Identifiable {
    var id: String { "\(type.rawValue)-\(pattern)" }
}

// MARK: - Node Subscription Rules

struct NodeSubscriptionRulesRow: View {
    @ObservedObject var manager = SubscriptionManager.shared
    let subscription: Subscription
    @State private var showingDetail = false

    private var effectiveEnabled: Bool { subscription.rulesEnabled ?? true }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(subscription.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text("\(subscription.rules.count) \(LocalizationManager.string("rule.rules_count"))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { effectiveEnabled },
                set: { newVal in manager.setRulesEnabled(subscriptionID: subscription.id, enabled: newVal) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(subscription.rules.isEmpty)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !subscription.rules.isEmpty { showingDetail = true }
        }
        .sheet(isPresented: $showingDetail) {
            NodeSubscriptionRulesDetailView(subscription: subscription)
        }
    }
}

struct NodeSubscriptionRulesDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: Subscription

    private let previewLimit = 200

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(LocalizationManager.string("rule.source"), value: subscription.name)
                    LabeledContent(LocalizationManager.string("label.total_rules"), value: "\(subscription.rules.count)")
                    if subscription.rules.count > previewLimit {
                        Text(String(format: LocalizationManager.string("rule.preview_limit_note"), previewLimit))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Section(LocalizationManager.string("tab.rules")) {
                    ForEach(Array(subscription.rules.prefix(previewLimit).enumerated()), id: \.offset) { _, rule in
                        RuleRowView(rule: rule)
                    }
                }
            }
            .navigationTitle(subscription.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationManager.string("rule.detail_done")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - BaseRuleset Support

struct BaseRulesetView: View {
    @State private var rules: [ProxyRule] = []
    @State private var editingRule: ProxyRule?
    @State private var showingResetAlert = false

    var body: some View {
        List {
            Section {
                Text(LocalizationManager.string("ruleset.base_desc"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section(LocalizationManager.string("ruleset.internal")) {
                if rules.isEmpty {
                    Text(LocalizationManager.string("ruleset.empty_base"))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(rules.indices, id: \.self) { index in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(rules[index].pattern)
                                    .font(.system(.subheadline, design: .monospaced))
                                Text(rules[index].type.rawValue.uppercased())
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(2)
                            }
                            Spacer()
                            Text(rules[index].action.rawValue.uppercased())
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(color(for: rules[index].action))
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                rules.remove(at: index)
                                saveBaseRules()
                            } label: {
                                Label(LocalizationManager.string("rule.delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
            
            Section {
                Button(action: {
                    showingResetAlert = true
                }) {
                    Label(LocalizationManager.string("ruleset.reset_defaults"), systemImage: "arrow.counterclockwise")
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle(LocalizationManager.string("ruleset.base_ruleset"))
        .onAppear {
            loadBaseRules()
        }
        .alert(LocalizationManager.string("ruleset.reset_alert_title"), isPresented: $showingResetAlert) {
            Button(LocalizationManager.string("rule.cancel"), role: .cancel) { }
            Button(LocalizationManager.string("ruleset.reset_button"), role: .destructive) {
                rules = Configuration.defaultRules
                saveBaseRules()
            }
        } message: {
            Text(LocalizationManager.string("ruleset.reset_alert_message"))
        }
    }

    private func loadBaseRules() {
        rules = Configuration.shared.load().baseRules
    }

    private func saveBaseRules() {
        var config = Configuration.shared.load()
        config.baseRules = rules
        Configuration.shared.save(config)
    }

    private func color(for action: ProxyRule.RuleAction) -> Color {
        switch action {
        case .direct: return .green
        case .proxy: return .blue
        case .reject: return .red
        }
    }
}
