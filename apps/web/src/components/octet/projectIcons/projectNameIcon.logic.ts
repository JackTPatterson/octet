/**
 * An icon for a project from what its name says, as native Octet does: "toolbox" gets a
 * wrench, "fantasy-hockey" a trophy, "pay-api" a card. The first rule whose word shows up in
 * the name wins, so more specific rules come first. `null` when nothing matches, and the
 * project keeps its initials.
 */

export type ProjectNameIconKey =
  | "wrench"
  | "trophy"
  | "gamepad"
  | "spade"
  | "chart-line"
  | "bitcoin"
  | "credit-card"
  | "dollar"
  | "chart-pie"
  | "chart-bar"
  | "database"
  | "sparkles"
  | "brain"
  | "shield-lock"
  | "key"
  | "landmark"
  | "bug"
  | "badge-check"
  | "flask"
  | "heart-pulse"
  | "dumbbell"
  | "utensils"
  | "coffee"
  | "plane"
  | "map"
  | "car"
  | "package"
  | "hammer"
  | "house"
  | "bolt"
  | "cloud-sun"
  | "leaf"
  | "paw"
  | "baby"
  | "cpu"
  | "bot"
  | "music"
  | "video"
  | "image"
  | "palette"
  | "mail"
  | "messages"
  | "users"
  | "megaphone"
  | "cart"
  | "graduation"
  | "book"
  | "newspaper"
  | "calendar"
  | "clock"
  | "checklist"
  | "search"
  | "radar"
  | "cloud"
  | "server"
  | "terminal"
  | "puzzle"
  | "monitor"
  | "smartphone"
  | "globe"
  | "code"
  | "hexagon-grid";

interface Rule {
  readonly words: ReadonlySet<string>;
  readonly icon: ProjectNameIconKey;
}

const rule = (words: string, icon: ProjectNameIconKey): Rule => ({
  words: new Set(words.split(" ")),
  icon,
});

// A word of four letters or more matches the start of a name's word ("tool" finds "tools" and
// "toolkit"); shorter ones must match whole.
const RULES: ReadonlyArray<Rule> = [
  rule("tool tools toolkit toolbox util utils utility utilities", "wrench"),
  rule("hockey nhl puck rink football nfl gridiron basketball nba hoops baseball mlb softball soccer futbol mls fifa golf tennis pickleball fantasy sport sports league espn draft", "trophy"),
  rule("chess game games gaming arcade play unity unreal godot", "gamepad"),
  rule("blackjack casino poker dice bet betting gambling slots roulette", "spade"),
  rule("trading trader trade quant stock stocks equity equities options futures forex market markets hedge backtest alpha", "chart-line"),
  rule("crypto coin bitcoin btc ethereum eth defi nft web3 blockchain solana token wallet", "bitcoin"),
  rule("pay payment payments billing stripe invoice invoices checkout subscription subscriptions paddle revenue", "credit-card"),
  rule("finance bank banking budget expense expenses money cash accounting tax taxes ledger", "dollar"),
  rule("invest investing portfolio fund funds", "chart-pie"),
  rule("analytics dashboard metrics stats statistics report reports insight insights bi kpi", "chart-bar"),
  rule("data dataset datasets etl pipeline pipelines warehouse database db sql postgres postgresql mysql sqlite mongo redis supabase prisma storage cache", "database"),
  rule("ai ml llm gpt agent agents bot bots claude openai neural copilot assistant prompt prompts rag", "sparkles"),
  rule("brain model models training inference", "brain"),
  rule("security secure auth authentication oauth sso vault secret secrets privacy password passwords access iam", "shield-lock"),
  rule("key keys keychain", "key"),
  rule("compliance legal law lawyer contract contracts policy policies terms gdpr", "landmark"),
  rule("bug bugs debug debugger", "bug"),
  rule("test tests testing qa e2e spec specs", "badge-check"),
  rule("lab labs experiment experiments sandbox playground scratch prototype prototypes poc bio biotech pharma pharmacy vial dna gene genome chemistry science", "flask"),
  rule("health healthcare medical medicine med clinic hospital patient wellness therapy", "heart-pulse"),
  rule("fitness workout gym lift run running yoga", "dumbbell"),
  rule("food recipe recipes cook cooking restaurant meal meals kitchen diet nutrition", "utensils"),
  rule("coffee cafe tea", "coffee"),
  rule("travel trip trips flight flights hotel vacation airline airport", "plane"),
  rule("map maps location geo gps atlas navigation", "map"),
  rule("car cars auto automotive vehicle ride rides driving taxi", "car"),
  rule("fleet logistics shipping delivery freight cargo supply", "package"),
  rule("construction contractor contractors builder building site jobsite crew", "hammer"),
  rule("real estate property properties rent rental housing mortgage home house smart iot homekit", "house"),
  rule("energy solar power battery electric grid ev charging", "bolt"),
  rule("climate weather forecast earth eco green environment carbon", "cloud-sun"),
  rule("plant plants garden gardening farm farming agriculture", "leaf"),
  rule("pet pets dog dogs cat cats vet", "paw"),
  rule("baby kids kid parenting family", "baby"),
  rule("hardware pcb firmware arduino esp32 sensor sensors chip chips fpga glasses wearable", "cpu"),
  rule("robot robots robotics drone drones", "bot"),
  rule("music audio song songs sound podcast radio spotify playlist playlists beat beats synth dance dancing choreo", "music"),
  rule("video videos film movie movies stream streaming youtube tiktok reels clip clips editor cinema tv", "video"),
  rule("photo photos image images camera gallery picture pictures wallpaper", "image"),
  rule("design designer figma art logo logos icon icons brand branding ui ux style theme themes", "palette"),
  rule("mail email emails inbox newsletter smtp mailpit postal", "mail"),
  rule("chat message messages messaging slack discord sms whatsapp telegram", "messages"),
  rule("social community forum forums reddit twitter threads network people team teams hr hiring recruit recruiting jobs crm contacts", "users"),
  rule("sales leads lead outreach prospect prospects funnel marketing growth seo ads advertising campaign campaigns content creator creators influencer affiliate", "megaphone"),
  rule("shop shopify store stores ecommerce commerce dropship dropshipping wholesale marketplace cart retail listing listings amazon etsy", "cart"),
  rule("learn learning course courses school edu education study tutorial tutorials academy teach teaching class classroom quiz", "graduation"),
  rule("book books docs doc documentation wiki blog notes note writing journal read reading ebook essay", "book"),
  rule("news feed feeds rss press", "newspaper"),
  rule("calendar schedule scheduler booking appointments events planner", "calendar"),
  rule("time clock timer cron reminder reminders habit habits tracker", "clock"),
  rule("todo todos task tasks checklist kanban board", "checklist"),
  rule("search scrape scraper crawl crawler spider firecrawl seeding discover", "search"),
  rule("monitor watch watcher alert alerts uptime status sweep radar scanner scan observability grafana", "radar"),
  rule("ops devops sre infra infrastructure cloud aws gcp azure k8s kubernetes docker deploy deployment hosting terraform ansible", "cloud"),
  rule("server servers backend api apis rest graphql grpc service services microservice engine", "server"),
  rule("terminal shell cli console tui cmux ghostty tmux zsh bash", "terminal"),
  rule("sdk lib library libs framework plugin plugins extension extensions package packages module modules", "puzzle"),
  rule("mac macos osx desktop electron tauri appkit", "monitor"),
  rule("ios iphone android mobile app apps swiftui flutter expo react-native", "smartphone"),
  rule("web website websites site landing homepage portfolio frontend nextjs next vite astro svelte react vue", "globe"),
  rule("code coding dev developer repo repository monorepo", "code"),
  rule("hub nexus orbit drift swarm herd mesh cluster octet", "hexagon-grid"),
];

/** "fantasyEngine", "fantasy-engine" and "Fantasy_Engine" all read as "fantasy" and "engine". */
export function projectNameTokens(name: string): string[] {
  const words: string[] = [];
  let current = "";
  let previous = "";
  for (const character of name) {
    if (!/[\p{L}\p{N}]/u.test(character)) {
      if (current) words.push(current);
      current = "";
    } else {
      if (
        current &&
        previous !== "" &&
        character !== character.toLowerCase() &&
        previous === previous.toLowerCase() &&
        /\p{L}/u.test(previous)
      ) {
        words.push(current);
        current = "";
      }
      current += character;
    }
    previous = character;
  }
  if (current) words.push(current);
  return words.map((word) => word.toLowerCase());
}

const cache = new Map<string, ProjectNameIconKey | null>();

export function projectNameIcon(name: string): ProjectNameIconKey | null {
  const cached = cache.get(name);
  if (cached !== undefined) return cached;
  const words = projectNameTokens(name);
  let found: ProjectNameIconKey | null = null;
  if (words.length > 0) {
    for (const candidate of RULES) {
      const hit = [...candidate.words].some((keyword) =>
        words.some((word) => word === keyword || (keyword.length >= 4 && word.startsWith(keyword))),
      );
      if (hit) {
        found = candidate.icon;
        break;
      }
    }
  }
  cache.set(name, found);
  return found;
}
