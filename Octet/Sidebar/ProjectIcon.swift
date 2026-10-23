import AppKit

/// A symbol for a project from what its name says: "toolbox" gets a wrench,
/// "fantasy-hockey" a puck, "pay-api" a card. The first rule whose word
/// shows up in the name wins, so more specific rules come first. nil when
/// nothing matches, and the tile keeps the project's initials.
enum ProjectIcon {
    private struct Rule {
        let words: [String]
        /// Candidates in order; the first one this macOS has is used.
        let symbols: [String]
        init(_ words: String, _ symbols: String...) {
            self.words = words.split(separator: " ").map(String.init)
            self.symbols = symbols
        }
    }

    // A word of four letters or more matches the start of a name's word
    // ("tool" finds "tools" and "toolkit"); shorter ones must match whole.
    private static let rules: [Rule] = [
        Rule("tool tools toolkit toolbox util utils utility utilities", "wrench.and.screwdriver.fill", "wrench.fill"),
        Rule("hockey nhl puck rink", "hockey.puck.fill", "hockey.puck", "sportscourt.fill"),
        Rule("football nfl gridiron", "football.fill", "sportscourt.fill"),
        Rule("basketball nba hoops", "basketball.fill", "sportscourt.fill"),
        Rule("baseball mlb softball", "baseball.fill", "sportscourt.fill"),
        Rule("soccer futbol mls fifa", "soccerball", "sportscourt.fill"),
        Rule("golf", "figure.golf", "flag.fill"),
        Rule("tennis pickleball", "tennisball.fill", "sportscourt.fill"),
        Rule("fantasy sport sports league espn draft", "sportscourt.fill", "trophy.fill"),
        Rule("chess", "crown.fill", "gamecontroller.fill"),
        Rule("blackjack casino poker dice bet betting gambling slots roulette", "suit.spade.fill", "die.face.5.fill"),
        Rule("game games gaming arcade play unity unreal godot", "gamecontroller.fill"),
        Rule("trading trader trade quant stock stocks equity equities options futures forex market markets hedge backtest alpha", "chart.line.uptrend.xyaxis"),
        Rule("crypto coin bitcoin btc ethereum eth defi nft web3 blockchain solana token wallet", "bitcoinsign.circle.fill", "bitcoinsign.circle"),
        Rule("pay payment payments billing stripe invoice invoices checkout subscription subscriptions paddle revenue", "creditcard.fill"),
        Rule("finance bank banking budget expense expenses money cash accounting tax taxes ledger", "dollarsign.circle.fill"),
        Rule("invest investing portfolio fund funds", "chart.pie.fill"),
        Rule("analytics dashboard metrics stats statistics report reports insight insights bi kpi", "chart.bar.xaxis"),
        Rule("data dataset datasets etl pipeline pipelines warehouse", "cylinder.split.1x2.fill", "externaldrive.fill"),
        Rule("database db sql postgres postgresql mysql sqlite mongo redis supabase prisma storage cache", "cylinder.split.1x2.fill", "externaldrive.fill"),
        Rule("ai ml llm gpt agent agents bot bots claude openai neural copilot assistant prompt prompts rag", "sparkles"),
        Rule("brain model models training inference", "brain.head.profile", "brain"),
        Rule("security secure auth authentication oauth sso vault secret secrets privacy password passwords access iam", "lock.shield.fill", "lock.fill"),
        Rule("key keys keychain", "key.fill"),
        Rule("compliance legal law lawyer contract contracts policy policies terms gdpr", "building.columns.fill", "scroll.fill"),
        Rule("bug bugs debug debugger", "ladybug.fill"),
        Rule("test tests testing qa e2e spec specs", "checkmark.seal.fill", "testtube.2"),
        Rule("lab labs experiment experiments sandbox playground scratch prototype prototypes poc", "flask.fill", "testtube.2"),
        Rule("bio biotech pharma pharmacy vial dna gene genome chemistry science", "testtube.2", "cross.vial.fill"),
        Rule("health healthcare medical medicine med clinic hospital patient wellness therapy", "cross.case.fill", "heart.text.square.fill"),
        Rule("fitness workout gym lift training run running yoga", "figure.run", "heart.fill"),
        Rule("food recipe recipes cook cooking restaurant meal meals kitchen diet nutrition", "fork.knife"),
        Rule("coffee cafe tea", "cup.and.saucer.fill"),
        Rule("travel trip trips flight flights hotel vacation airline airport", "airplane"),
        Rule("map maps location geo gps atlas navigation", "map.fill"),
        Rule("car cars auto automotive vehicle ride rides driving taxi", "car.fill"),
        Rule("fleet logistics shipping delivery freight cargo warehouse supply", "shippingbox.fill", "truck.box.fill"),
        Rule("construction contractor contractors builder building site jobsite crew", "hammer.fill"),
        Rule("real estate property properties rent rental housing mortgage", "house.fill", "building.2.fill"),
        Rule("home house smart iot homekit", "house.fill"),
        Rule("energy solar power battery electric grid utility ev charging", "bolt.fill"),
        Rule("climate weather forecast earth eco green environment carbon", "cloud.sun.fill", "leaf.fill"),
        Rule("plant plants garden gardening farm farming agriculture", "leaf.fill"),
        Rule("pet pets dog dogs cat cats vet", "pawprint.fill"),
        Rule("baby kids kid parenting family", "figure.and.child.holdinghands", "heart.fill"),
        Rule("hardware pcb firmware arduino esp32 sensor sensors chip chips fpga glasses wearable", "cpu.fill", "memorychip.fill"),
        Rule("robot robots robotics drone drones", "gearshape.2.fill"),
        Rule("music audio song songs sound podcast radio spotify playlist playlists beat beats synth", "music.note", "waveform"),
        Rule("dance dancing choreo", "figure.dance", "music.note"),
        Rule("video videos film movie movies stream streaming youtube tiktok reels clip clips editor cinema tv", "play.rectangle.fill", "video.fill"),
        Rule("photo photos image images camera gallery picture pictures wallpaper", "photo.fill"),
        Rule("design designer figma art logo logos icon icons brand branding ui ux style theme themes", "paintpalette.fill", "paintbrush.fill"),
        Rule("mail email emails inbox newsletter smtp mailpit postal", "envelope.fill"),
        Rule("chat message messages messaging slack discord sms whatsapp telegram", "bubble.left.and.bubble.right.fill", "bubble.left.fill"),
        Rule("social community forum forums reddit twitter threads network", "person.2.fill"),
        Rule("people team teams hr hiring recruit recruiting jobs crm contacts", "person.2.fill"),
        Rule("sales leads lead outreach prospect prospects pipeline funnel", "megaphone.fill", "person.crop.circle.badge.plus"),
        Rule("marketing growth seo ads advertising campaign campaigns content creator creators influencer affiliate", "megaphone.fill"),
        Rule("shop shopify store stores ecommerce commerce dropship dropshipping wholesale marketplace cart retail listing listings amazon etsy", "cart.fill", "bag.fill"),
        Rule("learn learning course courses school edu education study tutorial tutorials academy teach teaching class classroom quiz", "graduationcap.fill"),
        Rule("book books docs doc documentation wiki blog notes note writing journal read reading ebook essay", "book.fill", "doc.text.fill"),
        Rule("news feed feeds rss press", "newspaper.fill"),
        Rule("calendar schedule scheduler booking appointments events planner", "calendar"),
        Rule("time clock timer cron reminder reminders habit habits tracker", "clock.fill"),
        Rule("todo todos task tasks checklist kanban board", "checklist"),
        Rule("search scrape scraper crawl crawler spider firecrawl seeding discover", "magnifyingglass"),
        Rule("monitor watch watcher alert alerts uptime status sweep radar scanner scan observability grafana", "dot.radiowaves.left.and.right", "scope"),
        Rule("ops devops sre infra infrastructure cloud aws gcp azure k8s kubernetes docker deploy deployment hosting terraform ansible", "cloud.fill", "server.rack"),
        Rule("server servers backend api apis rest graphql grpc service services microservice engine", "server.rack", "network"),
        Rule("terminal shell cli console tui cmux ghostty tmux zsh bash", "terminal.fill", "apple.terminal.fill"),
        Rule("sdk lib library libs framework plugin plugins extension extensions package packages module modules", "puzzlepiece.extension.fill", "shippingbox.fill"),
        Rule("mac macos osx desktop electron tauri appkit", "desktopcomputer"),
        Rule("ios iphone android mobile app apps swiftui flutter expo react-native", "iphone"),
        Rule("web website websites site landing homepage portfolio frontend nextjs next vite astro svelte react vue", "globe"),
        Rule("code coding dev developer repo repository monorepo", "chevron.left.forwardslash.chevron.right"),
        Rule("hub nexus orbit drift swarm herd mesh cluster", "circle.hexagongrid.fill", "network"),
        Rule("octet", "circle.hexagongrid.fill"),
    ]

    /// The symbol for `name`, or nil to keep its initials.
    static func symbol(for name: String) -> String? {
        if let cached = cache.withLock({ $0[name] }) { return cached.value }
        let found = lookup(name)
        cache.withLock { $0[name] = Box(value: found) }
        return found
    }

    private struct Box { let value: String? }
    private static let cache = LockedBox<[String: Box]>([:])

    private static func lookup(_ name: String) -> String? {
        let words = tokens(name)
        guard !words.isEmpty else { return nil }
        for rule in rules where rule.words.contains(where: { keyword in
            words.contains { word in
                word == keyword || (keyword.count >= 4 && word.hasPrefix(keyword))
            }
        }) {
            if let symbol = rule.symbols.first(where: exists) { return symbol }
        }
        return nil
    }

    private static func exists(_ symbol: String) -> Bool {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
    }

    /// "fantasyEngine", "fantasy-engine" and "Fantasy_Engine" all read as
    /// "fantasy" and "engine".
    private static func tokens(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            if !(character.isLetter || character.isNumber) {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                if character.isUppercase, let previous, previous.isLowercase, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }
}

/// A value behind a lock, for the cache above.
final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
