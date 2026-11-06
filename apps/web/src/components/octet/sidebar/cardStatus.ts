import type { SidebarThreadStatus } from "../../Sidebar.logic";

// The top-right status T3's thread rows show, by status (SidebarThreadRow's topStatus).
export const STATUS_LABEL: Partial<Record<SidebarThreadStatus, { label: string; className: string }>> = {
  working: { label: "Working", className: "text-info-foreground" },
  waiting: { label: "Waiting", className: "text-muted-foreground" },
  approval: { label: "Approval", className: "text-warning-foreground" },
  input: { label: "Input", className: "text-indigo-600 dark:text-indigo-300" },
  request: { label: "Request", className: "text-guest-foreground" },
  limited: { label: "Limited", className: "text-warning-foreground" },
  failed: { label: "Failed", className: "text-error-foreground" },
};
