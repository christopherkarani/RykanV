"use client";

import { useEffect, useState, useCallback } from "react";
import { fetchStatus, runAction } from "./lib/api";
import type { StatusResponse } from "./lib/types";
import { FeedHealthNotice, MachineContextFields } from "./lib/dashboard-mode";
import { STATUS_POLL_INTERVAL, ACTION_LABELS } from "./lib/constants";
import { useToast } from "./hooks/useToast";
import { useCommandOutput } from "./hooks/useCommandOutput";
import ErrorBoundary from "./components/ErrorBoundary";
import PageHeader from "./components/PageHeader";
import SectionHeader from "./components/SectionHeader";
import StatCard from "./components/StatCard";
import SkeletonCard from "./components/SkeletonCard";
import ActionTile from "./components/ActionTile";
import StatusBadge from "./components/StatusBadge";
import { ShieldCheck, ShieldX, Ban, Folder } from "lucide-react";

function OverviewContent() {
  const [data, setData] = useState<StatusResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [runningActions, setRunningActions] = useState<Set<string>>(new Set());
  const { enqueue } = useToast();
  const { append, expand } = useCommandOutput();

  const load = useCallback(async () => {
    try {
      const status = await fetchStatus();
      setData(status);
    } catch (err) {
      enqueue(err instanceof Error ? err.message : "Failed to load status", "error");
    } finally {
      setLoading(false);
    }
  }, [enqueue]);

  useEffect(() => {
    load();
    const id = setInterval(load, STATUS_POLL_INTERVAL);
    return () => clearInterval(id);
  }, [load]);

  const handleAction = useCallback(
    async (actionId: string) => {
      setRunningActions((prev) => new Set(prev).add(actionId));
      expand();
      append(`$ ${actionId}`);
      try {
        const result = await runAction(actionId);
        const output = [`$ ${actionId}`, `exit ${result.exit_code}`, result.stdout || "", result.stderr ? `stderr:\n${result.stderr}` : ""]
          .filter(Boolean)
          .join("\n\n");
        append(output);
        enqueue(result.ok ? "Command completed" : "Command returned a non-zero result", result.ok ? "success" : "error");
        load();
      } catch (err) {
        append(err instanceof Error ? err.message : "Command failed");
        enqueue(err instanceof Error ? err.message : "Command failed", "error");
      } finally {
        setRunningActions((prev) => {
          const next = new Set(prev);
          next.delete(actionId);
          return next;
        });
      }
    },
    [append, expand, enqueue, load]
  );

  const stats = !data
    ? []
    : [
        {
          label: "Version",
          value: data.ryk.version,
          detail: data.ryk.workspace_root ?? "Machine-wide",
          status: "success" as const,
        },
        ...(data.policy ? [{
          label: "Policy",
          value: data.policy.exists ? (data.policy.valid ? "Valid" : "Invalid") : "Missing",
          detail: data.policy.exists ? data.policy.path : "Create one from a preset",
          status: (data.policy.exists ? (data.policy.valid ? "success" : "error") : "warning") as "success" | "error" | "warning",
        }] : []),
        ...(data.secretless_runtime ? [{
          label: "Secretless",
          value: data.secretless_runtime.available ? "Available" : "Unavailable",
          detail: `${data.secretless_runtime.active_broker.label}: references only`,
          status: (data.secretless_runtime.available ? "success" : "warning") as "success" | "warning",
        }] : []),
        {
          label: "Report export",
          value: "Free",
          detail: "Safety reports available without a license",
          status: "success" as const,
        },
        ...(data.ci_readiness ? [{
          label: "CI",
          value: data.ci_readiness.ok ? "Ready" : "Needs work",
          detail: data.ci_readiness.error || data.ci_readiness.checks.map((c) => `${c.name}: ${c.status}`).join(", "),
          status: (data.ci_readiness.ok ? "success" : "warning") as "success" | "warning",
        }] : []),
        {
          label: "Prevented",
          value: `${data.blocked_actions.length}`,
          detail: data.blocked_actions.length === 1 ? "Blocked action found" : "Blocked actions found",
          status: (data.blocked_actions.length > 0 ? "warning" : "success") as "success" | "warning",
        },
        {
          label: "Sessions",
          value: `${data.sessions.length}`,
          detail: `${data.sessions.filter((s) => s.verified).length} verified`,
          status: "neutral" as const,
        },
      ];

  return (
    <div className="space-y-10" data-dashboard-mode="machine-wide-capable">
      <PageHeader title="Overview" subtitle="ryk runtime status, quick actions, and recent activity." />

      {data ? <FeedHealthNotice status={data} /> : null}

      <section aria-labelledby="stats-title">
        <h2 id="stats-title" className="sr-only">Stats</h2>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {loading
            ? Array.from({ length: 8 }).map((_, i) => <SkeletonCard key={i} />)
            : !data
              ? (
                <div className="col-span-full flex flex-col items-center gap-3 rounded-card border border-dashed border-border bg-surface/50 p-8 text-center">
                  <div className="flex h-10 w-10 items-center justify-center rounded-full bg-surface-elevated">
                    <ShieldX size={18} className="text-warning" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-text-secondary">Unable to load status</p>
                    <p className="mt-0.5 text-xs text-text-tertiary">Make sure ryk is running and try again.</p>
                  </div>
                </div>
              )
              : stats.map((s) => (
                  <StatCard key={s.label} label={s.label} value={s.value} detail={s.detail} status={s.status} />
                ))}
        </div>
      </section>

      {data?.mode === "machine" ? (
        <section aria-labelledby="workspaces-title">
          <SectionHeader title="Workspaces" subtitle={`${data.workspace_count} registered across this computer`} />
          {data.workspaces.length === 0 ? (
            <div className="rounded-card border border-dashed border-border bg-surface/50 p-8 text-center text-sm text-text-secondary">
              Workspaces appear after ryk observes activity in them.
            </div>
          ) : (
            <div className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
              {data.workspaces.map((workspace) => (
                <div key={workspace.root} className="rounded-card border border-border bg-surface p-4">
                  <div className="flex items-start gap-3">
                    <Folder size={16} className="mt-0.5 shrink-0 text-accent" />
                    <div className="min-w-0">
                      <p className="truncate font-mono text-sm text-text-primary" title={workspace.root}>{workspace.root}</p>
                      <p className="mt-1 text-xs text-text-tertiary">Host: {workspace.last_host ?? "not recorded"}</p>
                      <p className="mt-1 text-xs text-text-tertiary">Last seen: {workspace.last_seen_at}</p>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </section>
      ) : null}

      <div className="grid grid-cols-1 gap-8 lg:grid-cols-2">
        <section aria-labelledby="quick-actions-title">
          <SectionHeader title="Quick actions" subtitle="Fixed ryk commands only" />
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
            {(data?.quick_actions ?? []).map((action) => (
              <ActionTile
                key={action.id}
                id={action.id}
                label={ACTION_LABELS[action.id] ?? action.id}
                loading={runningActions.has(action.id)}
                onClick={() => handleAction(action.id)}
              />
            ))}
          </div>
        </section>

        <section aria-labelledby="blocked-title">
          <SectionHeader title="Recently prevented" subtitle="From replay artifacts" />
          <div className="space-y-2.5">
            {!(data?.blocked_actions?.length) ? (
              <div className="flex flex-col items-center gap-3 rounded-card border border-dashed border-border bg-surface/50 p-8 text-center">
                <div className="flex h-10 w-10 items-center justify-center rounded-full bg-surface-elevated">
                  <Ban size={18} className="text-text-tertiary" />
                </div>
                <div>
                  <p className="text-sm font-medium text-text-secondary">No denied actions yet</p>
                  <p className="mt-0.5 text-xs text-text-tertiary">
                    Run ryk with an agent, then replay denied events here.
                  </p>
                </div>
              </div>
            ) : (
              data?.blocked_actions.slice(0, 4).map((action, i) => (
                <div
                  key={`${action.session_id}-${action.timestamp}-${action.event_type}-${action.target}-${i}`}
                  className="flex items-start gap-3 rounded-card border border-border bg-surface p-4 transition-colors hover:border-border-strong hover:bg-surface-hover"
                >
                  <div className="mt-0.5 shrink-0">
                    {action.verified ? (
                      <ShieldCheck size={15} className="text-success" />
                    ) : (
                      <ShieldX size={15} className="text-warning" />
                    )}
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center justify-between gap-2">
                      <span className="text-sm font-medium text-text-primary">{action.event_type}</span>
                      <StatusBadge variant={action.verified ? "success" : "warning"}>
                        {action.verified ? "verified" : "unverified"}
                      </StatusBadge>
                    </div>
                    <div className="mt-1 truncate font-mono text-[11px] text-text-secondary">{action.target}</div>
                    <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-text-tertiary">
                      <MachineContextFields workspaceRoot={action.workspace_root} host={action.host} />
                      <span>Decision: {action.decision ?? "deny"}</span>
                      <span>Rule: {action.rule ?? "not recorded"}</span>
                      <span>Reason: {action.reason ?? "not recorded"}</span>
                    </div>
                  </div>
                </div>
              ))
            )}
          </div>
        </section>
      </div>
    </div>
  );
}

export default function OverviewPage() {
  return (
    <ErrorBoundary>
      <OverviewContent />
    </ErrorBoundary>
  );
}
