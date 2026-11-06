import type { ProjectIconColor } from "@t3tools/contracts";
import {
  BabyIcon,
  BadgeCheckIcon,
  BitcoinIcon,
  BoltIcon,
  BookIcon,
  BotIcon,
  BrainIcon,
  BugIcon,
  CalendarIcon,
  CarIcon,
  ChartBarIcon,
  ChartLineIcon,
  ChartPieIcon,
  CircleDollarSignIcon,
  ClockIcon,
  CloudIcon,
  CloudSunIcon,
  CodeXmlIcon,
  CoffeeIcon,
  CpuIcon,
  CreditCardIcon,
  DatabaseIcon,
  DumbbellIcon,
  FlaskConicalIcon,
  GamepadIcon,
  GlobeIcon,
  GraduationCapIcon,
  HammerIcon,
  HeartPulseIcon,
  HouseIcon,
  ImageIcon,
  KeyIcon,
  LandmarkIcon,
  LeafIcon,
  type LucideIcon,
  MailIcon,
  MapIcon,
  MegaphoneIcon,
  MessagesSquareIcon,
  MonitorIcon,
  MusicIcon,
  NewspaperIcon,
  PackageIcon,
  Palette,
  PawPrintIcon,
  PlaneIcon,
  PuzzleIcon,
  RadarIcon,
  SearchIcon,
  ServerIcon,
  ShieldIcon,
  ShoppingCartIcon,
  SmartphoneIcon,
  SparklesIcon,
  SpadeIcon,
  SquareCheckBigIcon,
  TerminalIcon,
  TrophyIcon,
  UsersIcon,
  UtensilsIcon,
  VideoIcon,
  WrenchIcon,
  HexagonIcon,
} from "lucide-react";

import { projectIconColorClassName } from "../../../projectIconColors";
import { cn } from "~/lib/utils";
import type { ProjectNameIconKey } from "./projectNameIcon.logic";

const ICONS: Record<ProjectNameIconKey, LucideIcon> = {
  wrench: WrenchIcon,
  trophy: TrophyIcon,
  gamepad: GamepadIcon,
  spade: SpadeIcon,
  "chart-line": ChartLineIcon,
  bitcoin: BitcoinIcon,
  "credit-card": CreditCardIcon,
  dollar: CircleDollarSignIcon,
  "chart-pie": ChartPieIcon,
  "chart-bar": ChartBarIcon,
  database: DatabaseIcon,
  sparkles: SparklesIcon,
  brain: BrainIcon,
  "shield-lock": ShieldIcon,
  key: KeyIcon,
  landmark: LandmarkIcon,
  bug: BugIcon,
  "badge-check": BadgeCheckIcon,
  flask: FlaskConicalIcon,
  "heart-pulse": HeartPulseIcon,
  dumbbell: DumbbellIcon,
  utensils: UtensilsIcon,
  coffee: CoffeeIcon,
  plane: PlaneIcon,
  map: MapIcon,
  car: CarIcon,
  package: PackageIcon,
  hammer: HammerIcon,
  house: HouseIcon,
  bolt: BoltIcon,
  "cloud-sun": CloudSunIcon,
  leaf: LeafIcon,
  paw: PawPrintIcon,
  baby: BabyIcon,
  cpu: CpuIcon,
  bot: BotIcon,
  music: MusicIcon,
  video: VideoIcon,
  image: ImageIcon,
  palette: Palette,
  mail: MailIcon,
  messages: MessagesSquareIcon,
  users: UsersIcon,
  megaphone: MegaphoneIcon,
  cart: ShoppingCartIcon,
  graduation: GraduationCapIcon,
  book: BookIcon,
  newspaper: NewspaperIcon,
  calendar: CalendarIcon,
  clock: ClockIcon,
  checklist: SquareCheckBigIcon,
  search: SearchIcon,
  radar: RadarIcon,
  cloud: CloudIcon,
  server: ServerIcon,
  terminal: TerminalIcon,
  puzzle: PuzzleIcon,
  monitor: MonitorIcon,
  smartphone: SmartphoneIcon,
  globe: GlobeIcon,
  code: CodeXmlIcon,
  "hexagon-grid": HexagonIcon,
};

/**
 * A project with no favicon of its own, shown as what its name says it is on the same
 * tinted tile as a monogram, in the project's colour.
 */
export function ProjectNameIcon({
  icon,
  color,
  className,
}: {
  readonly icon: ProjectNameIconKey;
  readonly color: ProjectIconColor;
  readonly className?: string | undefined;
}) {
  const Icon = ICONS[icon];
  return (
    <span
      aria-hidden="true"
      data-testid="project-name-icon"
      className={cn(
        "inline-flex size-4 shrink-0 items-center justify-center rounded-[25%]",
        projectIconColorClassName(color),
        className,
      )}
      style={{ backgroundColor: "color-mix(in srgb, currentColor 14%, transparent)" }}
    >
      <Icon className="size-[60%]" strokeWidth={2.25} />
    </span>
  );
}
