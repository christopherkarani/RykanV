"use client";

import { useEffect, useState, useCallback, useMemo } from "react";
import { fetchStatus, runAction } from "../lib/api";
import { sessionKey, type StatusResponse } from "../lib/types";
import { FeedHealthNotice, MachineContextFields } from "../lib/dashboard-mode";
import { useToast } from "../hooks/useToast";
import { useCommandOutput } from "../hooks/useCommandOutput";
import ErrorBoundary from "../components/ErrorBoundary";
import PageHeader from "../components/PageHeader";
import SectionHeader from "../components/SectionHeader";
import StatusBadge from "../components/StatusBadge";
import SkeletonCard from "../components/SkeletonCard";
import { ShieldCheck, ShieldX, Ban, Clock } from "lucide-react";
import { ActivityHostFilter, filterActionsByHost, PI_COVERAGE, RemediationActions } from "../components/ActivityControls";

function ActivityContent() {
  const [data, setData] = useState<StatusResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [selectedSession, setSelectedSession] = useState<string | null>(null);
  const [hostFilter, setHostFilter] = useState("all");
  const { enqueue } = useToast();
  const { append, expand } = useCommandOutput();

  const load = useCallback(async () => {
    try {
      const status = await fetchStatus();
      setData(status);
    } catch (err) {
      enqueue(err instanceof Error ? err.message : "Failed to load activity", "error");
    } finally {
      setLoading(false);
    }
  }, [enqueue]);

  useEffect(() => {
    load();
  }, [load]);

  const filteredActions = useMemo(() => {
    const actions = filterActionsByHost(data?.blocked_actions ?? [], hostFilter);
    if (!selectedSession) return actions;
    return actions.filter((a) => sessionKey({ id: a.session_id, workspace_root: a.workspace_root }) === selectedSession);
  }, [data, hostFilter, selectedSession]);

  const handleRun = useCallback(async (actionId: string) => {
    expand();
    append(`$ ${actionId}`);
    try {
      const result = await runAction(actionId);
      append([`exit ${result.exit_code}`, result.stdout, result.stderr].filter(Boolean).join("\n\n"));
      enqueue(result.ok ? "Command completed" : "Command returned a non-zero result", result.ok ? "success" : "error");
      load();
    } catch (error) {
      enqueue(error instanceof Error ? error.message : "Command failed", "error");
    }
  }, [append, enqueue, expand, load]);

  const handleCopy = useCallback(async (value: string, label: string) => {
    try {
      await navigator.clipboard.writeText(value);
      enqueue(`${label} copied`, "success");
    } catch {
      enqueue("Copy failed", "error");
    }
  }, [enqueue]);

  if (loading) {
    return (
      <div className="space-y-8">
        <PageHeader title="Activity" />
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-5">
          <div className="lg:col-span-2"><SkeletonCard /></div>
          <div className="lg:col-span-3"><SkeletonCard /></div>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-8" data-session-identity="workspace-root-and-id">
      <PageHeader title="Activity" subtitle="Session history and denied-action timeline." />

      {data ? <FeedHealthNotice status={data} /> : null}

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-5">
        <section className="lg:col-span-2">
          <SectionHeader title="Sessions" subtitle=".ryk/sessions" />
          <div className="space-y-2">
            {!(data?.sessions?.length) ? (
              <div className="flex flex-col items-center gap-3 rounded-card border border-dashed border-border bg-surface/50 p-8 text-center">
                <div className="flex h-10 w-10 items-center justify-center rounded-full bg-surface-elevated">
                  <Clock size={18} className="text-text-tertiary" />
                </div>
                <p className="text-sm text-text-secondary">No sessions yet</p>
                <p className="text-xs text-text-tertiary">Session artifacts appear after running an agent through ryk.</p>
              </div>
            ) : (
              (data?.sessions ?? []).map((session) => (
                <button
                  key={sessionKey(session)}
                  onClick={() => setSelectedSession((prev) => (prev === sessionKey(session) ? null : sessionKey(session)))}
                  className={`group flex w-full items-center gap-3 rounded-card border bg-surface p-4 text-left transition-all duration-micro hover:border-border-strong hover:bg-surface-hover ${
                    selectedSession === sessionKey(session)
                      ? "border-l-[3px] border-l-accent border-border"
                      : "border-border"
                  }`}
                >
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center justify-between gap-2">
                      <span className="truncate font-mono text-sm font-medium text-text-primary">{session.id}</span>
                      {session.verified ? (
                        <ShieldCheck size={14} className="shrink-0 text-success" />
                      ) : (
                        <ShieldX size={14} className="shrink-0 text-warning" />
                      )}
                    </div>
                    <div className="mt-1 text-[11px] text-text-tertiary">
                      {session.command ?? "unknown"} · {session.denied_count} denied
                    </div>
                    <div className="mt-1 flex flex-col truncate text-[11px] text-text-tertiary" title={session.workspace_root}>
                      <MachineContextFields workspaceRoot={session.workspace_root} host={session.host} />
                    </div>
                  </div>
                </button>
              ))
            )}
          </div>
        </section>

        <section className="lg:col-span-3">
          <SectionHeader title="Denied timeline" subtitle="Target, rule, reason, verification" />
          <div className="mb-4 space-y-3">
            <ActivityHostFilter actions={data?.blocked_actions ?? []} selected={hostFilter} onSelect={setHostFilter} />
            <p className="text-xs leading-5 text-text-tertiary">{PI_COVERAGE}</p>
          </div>
          <div className="space-y-4">
            {filteredActions.length === 0 ? (
              <div className="flex flex-col items-center gap-3 rounded-card border border-dashed border-border bg-surface/50 p-8 text-center">
                <div className="flex h-10 w-10 items-center justify-center rounded-full bg-surface-elevated">
                  <Ban size={18} className="text-text-tertiary" />
                </div>
                <p className="text-sm text-text-secondary">No denied actions recorded.</p>
              </div>
            ) : (
              <div className="relative space-y-4 pl-4">
                <div className="absolute left-[7px] top-2 bottom-2 w-px bg-border" />
                {filteredActions.map((action, i) => (
                  <div key={`${action.workspace_root}-${action.session_id}-${action.timestamp}-${action.event_type}-${action.target}-${i}`} className="relative pl-6">
                    <div className="absolute left-0 top-2 h-2 w-2 rounded-full border border-border bg-surface">
                      <div className={`h-full w-full rounded-full ${action.verified ? "bg-success" : "bg-warning"}`} />
                    </div>
                    <div className="rounded-card border border-border bg-surface p-4 transition hover:border-border-strong">
                      <div className="flex items-center justify-between gap-2">
                        <span className="text-sm font-medium text-text-primary">{action.event_type}</span>
                        <StatusBadge variant={action.verified ? "success" : "warning"}>
                          {action.verified ? "verified" : "unverified"}
                        </StatusBadge>
                      </div>
                      <div className="mt-1 truncate font-mono text-[11px] text-text-secondary">{action.target}</div>
                      <div className="mt-3 grid grid-cols-2 gap-3 text-[11px] sm:grid-cols-3">
                        {[
                          { label: "Decision", value: action.decision ?? "deny" },
                          { label: "Rule", value: action.rule ?? "not recorded" },
                          { label: "Reason", value: action.reason ?? "not recorded" },
                          { label: "Session", value: action.session_id },
                          { label: "Workspace", value: action.workspace_root },
                          { label: "Host", value: action.host ?? "not recorded" },
                        ].map((field) => (
                          <div key={field.label}>
                            <span className="block text-text-tertiary">{field.label}</span>
                            <span className={`block truncate text-text-secondary ${field.label === "Session" ? "font-mono" : ""}`}>
                              {field.value}
                            </span>
                          </div>
                        ))}
                      </div>
                      {data ? <RemediationActions action={action} mode={data.mode} onRun={handleRun} onCopy={handleCopy} /> : null}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        </section>
      </div>
    </div>
  );
}

export default function ActivityPage() {
  return (
    <ErrorBoundary>
      <ActivityContent />
    </ErrorBoundary>
  );
}
