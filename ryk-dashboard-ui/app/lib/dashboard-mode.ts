"use client";

import React, { createContext, useContext, useEffect, useState } from "react";

import { fetchStatus } from "./api.ts";
import { feedHealthMessage, type StatusResponse } from "./types.ts";

export type DashboardMode = "machine" | "workspace";

export interface DashboardModeState {
  mode: DashboardMode;
  loading: boolean;
}

export const DashboardModeContext = createContext<DashboardModeState>({ mode: "machine", loading: true });

export function DashboardModeProvider({ children }: { children: React.ReactNode }) {
  const [state, setState] = useState<DashboardModeState>({ mode: "machine", loading: true });

  useEffect(() => {
    let active = true;
    fetchStatus()
      .then((status) => {
        if (active) setState({ mode: status.mode, loading: false });
      })
      .catch(() => {
        if (active) setState({ mode: "machine", loading: false });
      });
    return () => { active = false; };
  }, []);

  return React.createElement(DashboardModeContext.Provider, { value: state }, children);
}

export function useDashboardMode(): DashboardModeState {
  return useContext(DashboardModeContext);
}

export function WorkspaceOnlyGate({ children }: { children: React.ReactNode }) {
  const { mode, loading } = useDashboardMode();
  if (loading) {
    return React.createElement("div", { className: "rounded-card border border-border bg-surface p-8 text-sm text-text-secondary" }, "Loading dashboard mode…");
  }
  if (mode === "workspace") return React.createElement(React.Fragment, null, children);
  return React.createElement(
    "section",
    { className: "mx-auto max-w-xl rounded-card border border-warning/40 bg-surface p-6", role: "status" },
    React.createElement("h1", { className: "text-lg font-semibold text-text-primary" }, "Select a workspace"),
    React.createElement(
      "p",
      { className: "mt-2 text-sm text-text-secondary" },
      "This page manages workspace-specific settings. Restart the dashboard with ",
      React.createElement("code", { className: "font-mono" }, "ryk dashboard --workspace <path>"),
      ".",
    ),
    React.createElement("a", { href: "/", className: "mt-4 inline-flex rounded-md bg-accent px-3 py-2 text-sm font-medium text-white" }, "Return to overview"),
  );
}

export function MachineContextFields({ workspaceRoot, host }: { workspaceRoot: string; host: string | null }) {
  return React.createElement(
    React.Fragment,
    null,
    React.createElement("span", null, `Workspace: ${workspaceRoot}`),
    React.createElement("span", null, `Host: ${host ?? "not recorded"}`),
  );
}

export function FeedHealthNotice({ status }: { status: Pick<StatusResponse, "feed_health" | "feed_skipped_lines"> }) {
  const message = feedHealthMessage(status);
  if (!message) return null;
  return React.createElement("div", { role: "status", className: "rounded-card border border-warning/40 bg-warning/10 p-4 text-sm text-warning" }, message);
}
