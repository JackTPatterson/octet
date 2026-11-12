import * as Cache from "effect/Cache";
import * as Context from "effect/Context";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Fiber from "effect/Fiber";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as PlatformError from "effect/PlatformError";
import * as Schema from "effect/Schema";

import * as WorkspacePaths from "../workspace/WorkspacePaths.ts";
import * as T3ProjectFileLoader from "./T3ProjectFileLoader.ts";

const FAVICON_CACHE_CAPACITY = 512;
const FAVICON_POSITIVE_CACHE_TTL = Duration.minutes(10);
const FAVICON_NEGATIVE_CACHE_TTL = Duration.minutes(1);

function faviconCacheKey(cwd: string, faviconPath?: string): string {
  return `${faviconPath ?? ""}\0${cwd}`;
}

function parseFaviconCacheKey(key: string): {
  readonly cwd: string;
  readonly faviconPath?: string;
} {
  const separatorIndex = key.indexOf("\0");
  if (separatorIndex === -1) {
    return { cwd: key };
  }
  const faviconPath = key.slice(0, separatorIndex);
  const cwd = key.slice(separatorIndex + 1);
  return faviconPath.length === 0 ? { cwd } : { cwd, faviconPath };
}

const FAVICON_CANDIDATES = [
  "favicon.svg",
  "favicon.ico",
  "favicon.png",
  "public/favicon.svg",
  "public/favicon.ico",
  "public/favicon.png",
  "app/favicon.ico",
  "app/favicon.png",
  "app/icon.svg",
  "app/icon.png",
  "app/icon.ico",
  "src/favicon.ico",
  "src/favicon.svg",
  "src/app/favicon.ico",
  "src/app/icon.svg",
  "src/app/icon.png",
  "assets/icon.svg",
  "assets/icon.png",
  "assets/logo.svg",
  "assets/logo.png",
  ".idea/icon.svg",
  "Resources/AppIcon.icns",
  "AppIcon.icns",
] as const;

/**
 * App icons, after any favicon: what a mobile, desktop or Apple app keeps its icon in, so a
 * project that is an app and not a website still gets a picture. Browser-renderable formats
 * only, largest sizes first.
 */
const APP_ICON_CANDIDATES = [
  "public/apple-touch-icon.png",
  "public/icon.png",
  "public/icon.svg",
  "public/logo.svg",
  "public/logo.png",
  "static/favicon.svg",
  "static/favicon.png",
  "static/favicon.ico",
  "static/icon.png",
  "src/assets/logo.svg",
  "src/assets/icon.png",
  // Expo and React Native.
  "assets/images/icon.png",
  "assets/images/adaptive-icon.png",
  "assets/images/favicon.png",
  "assets/adaptive-icon.png",
  // Electron and Tauri.
  "build/icon.png",
  "build/icon.svg",
  "resources/icon.png",
  "src-tauri/icons/icon.png",
  "src-tauri/icons/128x128@2x.png",
  "src-tauri/icons/128x128.png",
  "icons/icon.png",
  // Android.
  "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
  "android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png",
  "android/app/src/main/res/mipmap-xhdpi/ic_launcher.png",
  "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
  "app/src/main/res/mipmap-xxhdpi/ic_launcher.png",
] as const;

/** Where an Xcode project keeps its app icon set, relative to the project folder. */
const APP_ICON_SET_PARENTS = ["", "ios", "macos"] as const;
const APP_ICON_SET_CATALOGS = ["Images.xcassets", "Assets.xcassets"] as const;

/** The pixel size an `AppIcon.appiconset` image entry stands for ("60x60" at "3x" is 180). */
export function appIconEntryPixels(entry: {
  readonly size?: unknown;
  readonly scale?: unknown;
}): number {
  const size =
    typeof entry.size === "string" ? Number.parseFloat(entry.size.split("x")[0] ?? "") : NaN;
  const scale = typeof entry.scale === "string" ? Number.parseFloat(entry.scale) : 1;
  return Number.isFinite(size) ? size * (Number.isFinite(scale) ? scale : 1) : 0;
}

/** The file of the largest PNG in an `AppIcon.appiconset`'s Contents.json, or null. */
export function largestAppIconFile(contentsJson: string): string | null {
  try {
    const parsed = JSON.parse(contentsJson) as {
      readonly images?: ReadonlyArray<Record<string, unknown>>;
    };
    let best: { readonly file: string; readonly pixels: number } | null = null;
    for (const entry of parsed.images ?? []) {
      const file = entry.filename;
      if (typeof file !== "string" || !/\.png$/i.test(file)) continue;
      const pixels = appIconEntryPixels(entry);
      if (best === null || pixels > best.pixels) best = { file, pixels };
    }
    return best?.file ?? null;
  } catch {
    return null;
  }
}

/**
 * Where a monorepo keeps the projects that carry the icon (a web app in `apps/web`, a mobile
 * app in `apps/mobile`): searched, one level deep, only when the root has no icon of its own.
 */
const SUBPROJECT_PARENTS = ["apps", "packages"] as const;
const SUBPROJECT_DIRS = ["web", "site", "website", "www", "frontend", "client", "app"] as const;

const ICON_SOURCE_FILES = [
  "index.html",
  "public/index.html",
  "app/routes/__root.tsx",
  "src/routes/__root.tsx",
  "app/root.tsx",
  "src/root.tsx",
  "src/index.html",
] as const;

// Anchor HTML at <link and scan brace-free metadata runs to avoid quadratic regex rescans.
const LINK_ICON_HTML_RE =
  /<link\b(?=[^>]*\brel=["'](?:icon|shortcut icon)["'])(?=[^>]*\bhref=["']([^"'?]+))[^>]*>/i;
const ICON_REL_RE = /\brel\s*:\s*["'](?:icon|shortcut icon)["']/i;
const ICON_HREF_RE = /\bhref\s*:\s*["']([^"'?]+)/i;

export class ProjectFaviconResolutionError extends Schema.TaggedError<ProjectFaviconResolutionError>()(
  "ProjectFaviconResolutionError",
  {
    operation: Schema.Literals([
      "normalize-workspace",
      "resolve-path",
      "stat-candidate",
      "read-source",
    ]),
    workspaceRoot: Schema.String,
    relativePath: Schema.optional(Schema.String),
    absolutePath: Schema.optional(Schema.String),
    cause: Schema.Defect(),
  },
) {
  override get message(): string {
    return `Failed to resolve project favicon during ${this.operation} for workspace ${this.workspaceRoot}.`;
  }
}

const isWorkspaceRootNotExistsError = Schema.is(WorkspacePaths.WorkspaceRootNotExistsError);

export const isMissingWorkspaceRoot = (error: ProjectFaviconResolutionError): boolean =>
  error.operation === "normalize-workspace" && isWorkspaceRootNotExistsError(error.cause);

export class ProjectFaviconResolver extends Context.Service<
  ProjectFaviconResolver,
  {
    readonly resolvePath: (
      cwd: string,
      faviconPath?: string,
    ) => Effect.Effect<string | null, ProjectFaviconResolutionError>;
    /** Forgets cached lookups for a workspace whose files changed, such as a finished clone. */
    readonly invalidate: (cwd: string) => Effect.Effect<void>;
  }
>()("t3/project/ProjectFaviconResolver") {}

function extractIconHref(source: string): string | null {
  const htmlMatch = source.match(LINK_ICON_HTML_RE);
  if (htmlMatch?.[1]) return htmlMatch[1];
  for (const run of source.split("}")) {
    if (!ICON_REL_RE.test(run)) continue;
    const hrefMatch = run.match(ICON_HREF_RE);
    if (hrefMatch?.[1]) return hrefMatch[1];
  }
  return null;
}

export const optionOnNotFound = <A, R>(
  effect: Effect.Effect<A, PlatformError.PlatformError, R>,
): Effect.Effect<Option.Option<A>, PlatformError.PlatformError, R> =>
  effect.pipe(
    Effect.asSome,
    Effect.catchTags({
      PlatformError: (error) =>
        error.reason._tag === "NotFound" ? Effect.succeed(Option.none<A>()) : Effect.fail(error),
    }),
  );

export const make = Effect.gen(function* () {
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const workspacePaths = yield* WorkspacePaths.WorkspacePaths;
  const projectFileLoader = yield* T3ProjectFileLoader.T3ProjectFileLoader;

  const resolveIconHref = (href: string): ReadonlyArray<string> => {
    const clean = href.replace(/^\//, "");
    return [path.join("public", clean), clean];
  };

  const findExistingFile = Effect.fn("ProjectFaviconResolver.findExistingFile")(function* (
    projectCwd: string,
    relativeCandidates: ReadonlyArray<string>,
    candidateScope: "workspace" | "filesystem",
  ): Effect.fn.Return<string | null, ProjectFaviconResolutionError> {
    for (const relativePath of relativeCandidates) {
      const candidate = yield* (
        candidateScope === "filesystem" && path.isAbsolute(relativePath)
          ? Effect.succeed({ absolutePath: relativePath, relativePath })
          : workspacePaths.resolveRelativePathWithinRoot({
              workspaceRoot: projectCwd,
              relativePath,
            })
      ).pipe(
        Effect.asSome,
        Effect.catchTags({
          WorkspacePathOutsideRootError: () =>
            Effect.succeed(
              Option.none<{ readonly absolutePath: string; readonly relativePath: string }>(),
            ),
        }),
      );
      if (Option.isNone(candidate)) {
        continue;
      }
      const stats = yield* optionOnNotFound(fileSystem.stat(candidate.value.absolutePath)).pipe(
        Effect.mapError(
          (cause) =>
            new ProjectFaviconResolutionError({
              operation: "stat-candidate",
              workspaceRoot: projectCwd,
              relativePath,
              absolutePath: candidate.value.absolutePath,
              cause,
            }),
        ),
      );
      if (Option.isSome(stats) && stats.value.type === "File") {
        return candidate.value.absolutePath;
      }
    }
    return null;
  });

  const findIconFromSource = Effect.fn("ProjectFaviconResolver.findIconFromSource")(function* (
    projectCwd: string,
    sourceFile: string,
  ): Effect.fn.Return<string | null, ProjectFaviconResolutionError> {
    const sourcePath = yield* workspacePaths
      .resolveRelativePathWithinRoot({
        workspaceRoot: projectCwd,
        relativePath: sourceFile,
      })
      .pipe(
        Effect.mapError(
          (cause) =>
            new ProjectFaviconResolutionError({
              operation: "resolve-path",
              workspaceRoot: projectCwd,
              relativePath: sourceFile,
              cause,
            }),
        ),
      );
    const source = yield* optionOnNotFound(fileSystem.readFileString(sourcePath.absolutePath)).pipe(
      Effect.mapError(
        (cause) =>
          new ProjectFaviconResolutionError({
            operation: "read-source",
            workspaceRoot: projectCwd,
            relativePath: sourceFile,
            absolutePath: sourcePath.absolutePath,
            cause,
          }),
      ),
    );
    if (Option.isNone(source)) {
      return null;
    }
    const href = extractIconHref(source.value);
    if (!href) {
      return null;
    }
    // An href is relative to the page, so also try it beside the source file
    // (`src/index.html` linking `assets/favicon.png` means `src/assets/favicon.png`).
    const besideSource = path.join(path.dirname(sourceFile), href.replace(/^\//, ""));
    return yield* findExistingFile(
      projectCwd,
      [...resolveIconHref(href), besideSource],
      "workspace",
    );
  });

  /** The largest icon of an Xcode `AppIcon.appiconset` one level below the project, if any. */
  const findAppIconSetImage = Effect.fn("ProjectFaviconResolver.findAppIconSetImage")(function* (
    projectCwd: string,
  ): Effect.fn.Return<string | null, ProjectFaviconResolutionError> {
    for (const parent of APP_ICON_SET_PARENTS) {
      // The root itself is not a path "within" the root, so it is taken as is.
      const parentPath =
        parent === ""
          ? { absolutePath: projectCwd }
          : yield* workspacePaths
              .resolveRelativePathWithinRoot({ workspaceRoot: projectCwd, relativePath: parent })
              .pipe(Effect.orElseSucceed(() => null));
      if (parentPath === null) continue;
      const entries = yield* fileSystem
        .readDirectory(parentPath.absolutePath)
        .pipe(Effect.orElseSucceed(() => [] as string[]));
      // The app target's folder, with its catalog inside; skip hidden and dependency folders.
      for (const entry of entries.toSorted()) {
        if (entry.startsWith(".") || entry === "node_modules" || entry === "Pods") continue;
        for (const catalog of APP_ICON_SET_CATALOGS) {
          const setDir = path.join(parentPath.absolutePath, entry, catalog, "AppIcon.appiconset");
          const contents = yield* fileSystem
            .readFileString(path.join(setDir, "Contents.json"))
            .pipe(Effect.orElseSucceed(() => null));
          if (contents === null) continue;
          const file = largestAppIconFile(contents);
          if (file === null) continue;
          const image = path.join(setDir, file);
          const stats = yield* fileSystem.stat(image).pipe(Effect.orElseSucceed(() => null));
          if (stats !== null && stats.type === "File") return image;
        }
      }
    }
    return null;
  });

  /** A monorepo's app folders (`apps/web`, `packages/ui`, `web`), in a stable order. */
  const findSubprojects = Effect.fn("ProjectFaviconResolver.findSubprojects")(function* (
    projectCwd: string,
  ): Effect.fn.Return<ReadonlyArray<string>> {
    const isDirectory = (dir: string) =>
      fileSystem.stat(dir).pipe(
        Effect.map((stats) => stats.type === "Directory"),
        Effect.orElseSucceed(() => false),
      );
    const found: string[] = [];
    for (const parent of SUBPROJECT_PARENTS) {
      const entries = yield* fileSystem
        .readDirectory(path.join(projectCwd, parent))
        .pipe(Effect.orElseSucceed(() => [] as string[]));
      for (const entry of entries.toSorted()) {
        if (entry.startsWith(".") || entry === "node_modules") continue;
        const dir = path.join(projectCwd, parent, entry);
        if (yield* isDirectory(dir)) found.push(dir);
      }
    }
    for (const name of SUBPROJECT_DIRS) {
      const dir = path.join(projectCwd, name);
      if (yield* isDirectory(dir)) found.push(dir);
    }
    return found;
  });

  // Probe concurrently but join in list order so lower-ranked probes cannot delay a hit.
  // A failure surfaces only if no earlier probe found a file; scope exit interrupts remaining probes.
  const firstInOrder = Effect.fn("ProjectFaviconResolver.firstInOrder")(function* <A>(
    items: ReadonlyArray<A>,
    probe: (item: A) => Effect.Effect<string | null, ProjectFaviconResolutionError>,
  ) {
    const fibers = yield* Effect.forEach(items, (item) => Effect.forkScoped(probe(item)));
    for (const fiber of fibers) {
      const found = yield* Fiber.join(fiber);
      if (found) {
        return found;
      }
    }
    return null;
  }, Effect.scoped);

  const resolvePathUncached = Effect.fn("ProjectFaviconResolver.resolvePathUncached")(function* (
    cwd: string,
    faviconPath?: string,
  ): Effect.fn.Return<string | null, ProjectFaviconResolutionError> {
    const projectCwd = yield* workspacePaths.normalizeWorkspaceRoot(cwd).pipe(
      Effect.mapError(
        (cause) =>
          new ProjectFaviconResolutionError({
            operation: "normalize-workspace",
            workspaceRoot: cwd,
            cause,
          }),
      ),
    );
    if (faviconPath !== undefined) {
      const existing = yield* findExistingFile(projectCwd, [faviconPath], "filesystem");
      if (existing) {
        return existing;
      }
    }

    const projectFile = yield* projectFileLoader.load(projectCwd);
    if (Option.isSome(projectFile) && projectFile.value.iconPath !== undefined) {
      const existing = yield* findExistingFile(
        projectCwd,
        [projectFile.value.iconPath],
        "workspace",
      );
      if (existing) {
        return existing;
      }
    }

    const wellKnown = yield* firstInOrder(FAVICON_CANDIDATES, (candidate) =>
      findExistingFile(projectCwd, [candidate], "workspace"),
    );
    if (wellKnown) {
      return wellKnown;
    }

    const fromSource = yield* firstInOrder(ICON_SOURCE_FILES, (sourceFile) =>
      findIconFromSource(projectCwd, sourceFile),
    );
    if (fromSource) {
      return fromSource;
    }

    // Not a website: an app's own icon.
    const appIcon = yield* firstInOrder(APP_ICON_CANDIDATES, (candidate) =>
      findExistingFile(projectCwd, [candidate], "workspace"),
    );
    if (appIcon) {
      return appIcon;
    }
    const appIconSet = yield* findAppIconSetImage(projectCwd);
    if (appIconSet) {
      return appIconSet;
    }

    // A monorepo: its apps' icons, each kind across all of them before the next, so a web
    // app's favicon wins over a mobile app's launcher icon.
    const subprojects = yield* findSubprojects(projectCwd);
    for (const probe of [
      (dir: string) =>
        firstInOrder(FAVICON_CANDIDATES, (candidate) =>
          findExistingFile(dir, [candidate], "workspace"),
        ),
      (dir: string) =>
        firstInOrder(ICON_SOURCE_FILES, (sourceFile) => findIconFromSource(dir, sourceFile)),
      (dir: string) =>
        firstInOrder(APP_ICON_CANDIDATES, (candidate) =>
          findExistingFile(dir, [candidate], "workspace"),
        ),
      findAppIconSetImage,
    ]) {
      const found = yield* firstInOrder(subprojects, probe);
      if (found) {
        return found;
      }
    }
    return null;
  });

  const faviconCache = yield* Cache.makeWith<string, string | null, ProjectFaviconResolutionError>(
    (key) => {
      const { cwd, faviconPath } = parseFaviconCacheKey(key);
      return resolvePathUncached(cwd, faviconPath);
    },
    {
      capacity: FAVICON_CACHE_CAPACITY,
      timeToLive: Exit.match({
        onSuccess: (value: string | null) =>
          value === null ? FAVICON_NEGATIVE_CACHE_TTL : FAVICON_POSITIVE_CACHE_TTL,
        onFailure: () => Duration.zero,
      }),
    },
  );

  const resolvePath: ProjectFaviconResolver["Service"]["resolvePath"] = Effect.fn(
    "ProjectFaviconResolver.resolvePath",
  )(function* (cwd, faviconPath) {
    const key = faviconCacheKey(cwd, faviconPath);
    const cached = yield* Cache.get(faviconCache, key);
    if (cached === null) {
      return null;
    }

    const stats = yield* optionOnNotFound(fileSystem.stat(cached)).pipe(
      Effect.mapError(
        (cause) =>
          new ProjectFaviconResolutionError({
            operation: "stat-candidate",
            workspaceRoot: cwd,
            absolutePath: cached,
            cause,
          }),
      ),
    );
    if (Option.isSome(stats) && stats.value.type === "File") {
      return cached;
    }

    yield* Cache.invalidate(faviconCache, key);
    return yield* Cache.get(faviconCache, key);
  });

  const invalidate: ProjectFaviconResolver["Service"]["invalidate"] = (cwd) =>
    Cache.keys(faviconCache).pipe(
      Effect.flatMap((keys) =>
        Effect.forEach(
          Array.from(keys).filter((key) => parseFaviconCacheKey(key).cwd === cwd),
          (key) => Cache.invalidate(faviconCache, key),
          { discard: true },
        ),
      ),
    );

  return ProjectFaviconResolver.of({ resolvePath, invalidate });
});

export const layer = Layer.effect(ProjectFaviconResolver, make);
