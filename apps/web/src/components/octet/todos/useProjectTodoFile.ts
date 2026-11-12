import type { EnvironmentId } from "@t3tools/contracts";
import { useEffect, useRef } from "react";
import { projectEnvironment } from "../../../state/projects";
import { useEnvironmentQuery } from "../../../state/query";
import { PROJECT_TODO_FILE_NAMES } from "./projectTodos.logic";

const REFRESH_MS = 2_500;

function useTodoFileRead(environmentId: EnvironmentId, cwd: string | null, relativePath: string) {
  return useEnvironmentQuery(
    cwd === null
      ? null
      : projectEnvironment.readFile({
          environmentId,
          input: { cwd, relativePath, allowMissing: true },
        }),
  );
}

/** The project's list: the first of the usual names that exists, else where a new one would go. */
export function useProjectTodoFile(environmentId: EnvironmentId, cwd: string | null) {
  const queries = [
    useTodoFileRead(environmentId, cwd, PROJECT_TODO_FILE_NAMES[0]),
    useTodoFileRead(environmentId, cwd, PROJECT_TODO_FILE_NAMES[1]),
    useTodoFileRead(environmentId, cwd, PROJECT_TODO_FILE_NAMES[2]),
    useTodoFileRead(environmentId, cwd, PROJECT_TODO_FILE_NAMES[3]),
  ];
  const index = queries.findIndex((query) => query.data && query.data.exists !== false);
  const found = index >= 0 ? queries[index]! : null;
  const refreshAll = useRef(() => {});
  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- polls the file while the panel is mounted, as agents and editors tick items elsewhere
  useEffect(() => {
    refreshAll.current = () => queries.forEach((query) => query.refresh());
  });
  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- polls the file while the panel is mounted, as agents and editors tick items elsewhere
  useEffect(() => {
    if (cwd === null) return;
    const timer = setInterval(() => refreshAll.current(), REFRESH_MS);
    return () => clearInterval(timer);
  }, [cwd]);
  return {
    fileName: index >= 0 ? PROJECT_TODO_FILE_NAMES[index]! : PROJECT_TODO_FILE_NAMES[0],
    contents: found?.data?.contents ?? "",
    loaded: queries.every((query) => !query.isPending) || found !== null,
    refresh: () => refreshAll.current(),
  };
}
