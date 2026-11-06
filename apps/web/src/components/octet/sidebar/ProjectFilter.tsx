import { pickableProjectGroups } from "@t3tools/client-runtime/state/project-grouping";
import { ListFilterIcon } from "lucide-react";

import type { SidebarProjectSnapshot } from "../../../sidebarProjectGrouping";
import { useUiStateStore } from "../../../uiStateStore";
import { ProjectFavicon } from "../../ProjectFavicon";
import { SidebarHeaderIconButton } from "../../sidebar/SidebarThreadHeader";
import {
  Menu,
  MenuCheckboxItem,
  MenuGroup,
  MenuGroupLabel,
  MenuItem,
  MenuPopup,
  MenuSeparator,
  MenuTrigger,
} from "../../ui/menu";

/**
 * Narrow the sidebar to some projects. It is T3's own project scope (the same
 * stored keys), so the choice follows between T3's sidebar and Octet's.
 */
export function ProjectFilter(props: {
  groups: readonly SidebarProjectSnapshot[];
  scopeKeys: readonly string[];
}) {
  const setScopeKeys = useUiStateStore((store) => store.setSidebarProjectScopeKeys);
  const pickable = pickableProjectGroups(props.groups);
  const chosen = pickable.filter((group) => props.scopeKeys.includes(group.projectKey));
  const toggle = (key: string) =>
    setScopeKeys(
      props.scopeKeys.includes(key)
        ? props.scopeKeys.filter((candidate) => candidate !== key)
        : [...props.scopeKeys, key],
    );
  return (
    <Menu>
      <MenuTrigger
        render={
          <SidebarHeaderIconButton
            label={
              chosen.length > 0
                ? `Filter by project: ${chosen.map((group) => group.displayName).join(", ")}`
                : "Filter by project"
            }
            data-testid="octet-project-filter"
          />
        }
      >
        {chosen.length === 1 ? (
          <ProjectFavicon project={chosen[0]!} className="size-4" />
        ) : (
          <ListFilterIcon className="size-4" />
        )}
      </MenuTrigger>
      <MenuPopup align="start">
        <MenuGroup>
          <MenuGroupLabel>Show projects</MenuGroupLabel>
          {pickable.map((group) => (
            <MenuCheckboxItem
              key={group.projectKey}
              checked={props.scopeKeys.includes(group.projectKey)}
              onCheckedChange={() => toggle(group.projectKey)}
            >
              <span className="flex min-w-0 items-center gap-2">
                <ProjectFavicon project={group} className="size-4 shrink-0" />
                <span className="truncate">{group.displayName}</span>
              </span>
            </MenuCheckboxItem>
          ))}
        </MenuGroup>
        {props.scopeKeys.length > 0 ? (
          <>
            <MenuSeparator />
            <MenuItem onClick={() => setScopeKeys([])}>Show all projects</MenuItem>
          </>
        ) : null}
      </MenuPopup>
    </Menu>
  );
}
