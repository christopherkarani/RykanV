"use client";

import { useEffect, useState, useCallback } from "react";
import { fetchStatus, runAction } from "../lib/api";
import type { StatusResponse } from "../lib/types";
import { useToast } from "../hooks/useToast";
import { useCommandOutput } from "../hooks/useCommandOutput";
import ErrorBoundary from "../components/ErrorBoundary";
import PageHeader from "../components/PageHeader";
import SectionHeader from "../components/SectionHeader";
import ActionTile from "../components/ActionTile";
import CodeBlock from "../components/CodeBlock";
import SkeletonCard from "../components/SkeletonCard";
import StatusBadge from "../components/StatusBadge";
import { Copy, Check, ShieldCheck, ShieldX, AlertTriangle } from "lucide-react";
import { WorkspaceOnlyGate } from "../lib/dashboard-mode";

function MetaItem({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-border bg-surface-elevated/60 px-3 py-2.5">
      <span className="block text-[11px] font-medium uppercase tracking-wider text-text-tertiary">{label}</span>
      <span className="mt-1 block text-sm font-medium text-text-primary">{value}</span>
    </div>
  );
}

function SecretlessContent() {
  const [data, setData] = useState<StatusResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [agentCommand, setAgentCommand] = useState("codex");
  const [copiedRun, setCopiedRun] = useState(false);
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
  }, [load]);

  const secretless = data?.secretless_runtime;
  const runCommand = `ryk run --secretless --network-backend proxy -- ${agentCommand.trim() || "<agent-command>"}`;

  const handleCopyRun = async () => {
    try {
      await navigator.clipboard.writeText(runCommand);
      setCopiedRun(true);
      setTimeout(() => setCopiedRun(false), 2000);
      enqueue("Secretless run command copied", "success");
    } catch {
      enqueue("Copy unavailable", "error");
    }
  };

  const handleVerifyAction = async (command: string) => {
    expand();
    append(`$ ${command}`);
    try {
      const result = await runAction(command);
      const output = [`$ ${command}`, `exit ${result.exit_code}`, result.stdout || "", result.stderr ? `stderr:\n${result.stderr}` : ""]
        .filter(Boolean)
        .join("\n\n");
      append(output);
      enqueue(result.ok ? "Command completed" : "Command returned non-zero", result.ok ? "success" : "error");
    } catch (err) {
      append(err instanceof Error ? err.message : "Command failed");
      enqueue(err instanceof Error ? err.message : "Command failed", "error");
    }
  };

  if (loading) {
    return (
      <div className="space-y-8">
        <PageHeader title="Secretless" />
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
          <SkeletonCard /><SkeletonCard />
        </div>
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
          <SkeletonCard /><SkeletonCard />
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-10">
      <PageHeader
        title="Secretless"
        subtitle="Runtime, broker references, and service policy."
        eyebrow="Secretless Agent Runtime"
        badge={secretless?.available ? { text: "available", variant: "success" } : { text: "unavailable", variant: "error" }}
      />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <section className="rounded-card border border-border bg-surface p-5">
          <SectionHeader
            title="Run command"
            subtitle="Generated locally; execution stays in your terminal"
            action={
              <button
                onClick={handleCopyRun}
                className="flex items-center gap-1.5 rounded-md border border-border bg-surface-elevated/60 px-2.5 py-1.5 text-[13px] text-text-secondary transition hover:bg-surface-hover hover:text-text-primary"
              >
                {copiedRun ? <Check size={13} className="text-success" /> : <Copy size={13} />}
                <span>{copiedRun ? "Copied" : "Copy"}</span>
              </button>
            }
          />
          <label htmlFor="agentCommand" className="text-sm font-medium text-text-primary">Agent command</label>
          <input
            id="agentCommand"
            type="text"
            value={agentCommand}
            onChange={(e) => setAgentCommand(e.target.value)}
            className="mt-2 w-full rounded-card border border-border bg-background-pure px-3 py-2 text-sm text-text-primary outline-none transition focus-visible:border-accent focus-visible:ring-1 focus-visible:ring-accent/30"
          />
          <code className="mt-3 block rounded-card border border-border bg-[#0a0a0a] p-3 font-mono text-sm text-text-primary">
            {runCommand}
          </code>
        </section>

        <section className="rounded-card border border-border bg-surface p-5">
          <SectionHeader title="Broker adapter" subtitle="References only; raw values stay out of ryk" />
          <div className="grid grid-cols-2 gap-2.5">
            <MetaItem label="Active broker" value={secretless?.active_broker.label ?? "—"} />
            <MetaItem label="Kind" value={secretless?.active_broker.kind ?? "—"} />
            <MetaItem label="Mode" value={secretless?.active_broker.status ?? "—"} />
            <MetaItem label="Stores raw secrets" value={secretless?.active_broker.stores_raw_secrets ? "yes" : "no"} />
          </div>
        </section>
      </div>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <section>
          <SectionHeader title="Service policy template" subtitle="Host, method, path, credential reference, unmatched" />
          <CodeBlock code={secretless?.service_policy_template ?? ""} lang="yaml" />
        </section>

        <section className="rounded-card border border-border bg-surface p-5">
          <SectionHeader title="Verification" subtitle="Commands that prove policy, explain, and replay behavior" />
          <div className="space-y-2">
            {secretless?.verify_commands.map((cmd) => (
              <ActionTile key={cmd} id={cmd} label={cmd} onClick={() => handleVerifyAction(cmd)} />
            ))}
          </div>
        </section>
      </div>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <section className="rounded-card border border-border bg-surface p-5">
          <SectionHeader title="Credential refs" subtitle="Declared refs only; raw values are never shown" />
          {secretless?.credential_refs.length === 0 ? (
            <div className="flex flex-col items-center gap-3 rounded-lg border border-dashed border-border bg-surface/50 p-8 text-center">
              <p className="text-sm text-text-secondary">No credential references declared.</p>
              <p className="text-xs text-text-tertiary">Add credentials.refs in .ryk/policy.yaml to map services.</p>
            </div>
          ) : (
            <div className="space-y-2">
              {secretless?.credential_refs.map((ref) => (
                <div key={ref.name} className="flex items-center gap-3 rounded-lg border border-border bg-surface-elevated/60 px-3 py-2.5 transition hover:border-border-strong">
                  <div className="min-w-0 flex-1">
                    <div className="text-sm font-medium text-text-primary">{ref.name}</div>
                    <div className="text-[11px] text-text-tertiary">{ref.broker ?? "default broker"}</div>
                  </div>
                  <code className="truncate font-mono text-[11px] text-text-secondary">{ref.ref}</code>
                  <StatusBadge variant="success" dot>redacted</StatusBadge>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className="rounded-card border border-border bg-surface p-5">
          <SectionHeader title="Proxy enforcement" subtitle="Explicit loopback proxy; HTTPS is host and port only" />
          <div className="grid grid-cols-2 gap-2.5">
            <MetaItem label="Status" value={secretless?.proxy_backend.status ?? "—"} />
            <MetaItem label="Backend" value={secretless?.proxy_backend.backend ?? "—"} />
            <MetaItem label="Bind" value={secretless?.proxy_backend.bind || "allocated per run"} />
            <MetaItem label="HTTPS visibility" value={secretless?.proxy_backend.https_visibility ?? "—"} />
          </div>
          {secretless?.proxy_backend.https_visibility === "host-port-only" && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-warning-muted px-3 py-2.5 text-sm text-warning">
              <AlertTriangle size={14} className="mt-0.5 shrink-0" />
              <span className="text-[13px]">HTTPS path and method enforcement is unavailable in proxy mode without MITM or cooperative metadata.</span>
            </div>
          )}
        </section>
      </div>

      <section className="rounded-card border border-border bg-surface p-5">
        <SectionHeader title="Broker checks" subtitle="Status evidence without resolved secret values" />
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          {secretless?.broker_checks.map((check) => (
            <div key={check.broker} className="rounded-lg border border-border bg-surface-elevated/60 p-4 transition hover:border-border-strong">
              <div className="flex items-center justify-between gap-2">
                <span className="text-sm font-medium text-text-primary">{check.broker}</span>
                <StatusBadge
                  variant={check.status === "available" ? "success" : check.status === "limited" ? "warning" : "error"}
                  dot
                >
                  {check.status}
                </StatusBadge>
              </div>
              <div className="mt-1 text-[11px] text-text-tertiary">Kind: {check.kind}</div>
              <p className="mt-2 text-[13px] leading-relaxed text-text-secondary">{check.message}</p>
            </div>
          ))}
        </div>
      </section>

      <section className="rounded-card border border-border bg-surface p-5">
        <SectionHeader title="Capability matrix" subtitle="What is active now and what remains an adapter boundary" />
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-border">
                <th className="pb-2.5 text-[11px] font-semibold uppercase tracking-wider text-text-tertiary">Feature</th>
                <th className="pb-2.5 text-[11px] font-semibold uppercase tracking-wider text-text-tertiary">Status</th>
                <th className="pb-2.5 text-[11px] font-semibold uppercase tracking-wider text-text-tertiary">Description</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border/60">
              {secretless?.capabilities.map((cap) => (
                <tr key={cap.label} className="transition hover:bg-surface-hover">
                  <td className="py-3 text-sm font-medium text-text-primary">{cap.label}</td>
                  <td className="py-3">
                    <StatusBadge
                      variant={cap.state === "active" ? "success" : cap.state === "limited" ? "warning" : "error"}
                      dot
                    >
                      {cap.state}
                    </StatusBadge>
                  </td>
                  <td className="py-3 text-[13px] text-text-secondary">{cap.detail}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="rounded-card border border-border bg-surface p-5">
        <SectionHeader title="Supported broker extension points" subtitle="ryk owns references and audit; external brokers own secret retrieval" />
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {secretless?.supported_brokers.map((broker) => (
            <div key={broker.id} className="rounded-lg border border-border bg-surface-elevated/60 p-4 transition hover:border-border-strong">
              <div className="flex items-center justify-between gap-2">
                <span className="text-sm font-medium text-text-primary">{broker.label}</span>
                <StatusBadge variant={broker.status === "available" ? "success" : "warning"} dot>
                  {broker.status}
                </StatusBadge>
              </div>
              <div className="mt-1 text-[11px] text-text-tertiary">ID: {broker.id}</div>
              <p className="mt-2 text-[13px] leading-relaxed text-text-secondary">{broker.notes}</p>
            </div>
          ))}
        </div>
      </section>

      <section className="rounded-card border border-border bg-surface p-5">
        <SectionHeader title="Recent broker and proxy events" subtitle="Redaction and proxy decisions from recent audit sessions" />
        <div className="space-y-2">
          {secretless?.recent_audit_events.length === 0 ? (
            <div className="flex flex-col items-center gap-3 rounded-lg border border-dashed border-border bg-surface/50 p-8 text-center">
              <p className="text-sm text-text-secondary">No recent evidence</p>
              <p className="text-xs text-text-tertiary">Run a secretless proxy session to populate request-level audit events.</p>
            </div>
          ) : (
            secretless?.recent_audit_events.map((ev, i) => (
              <div key={`${ev.session_id}-${ev.timestamp}-${ev.event_type}-${ev.target}-${i}`} className="flex items-start gap-3 rounded-lg border border-border bg-surface-elevated/60 p-3 transition hover:border-border-strong">
                <div className="mt-0.5 shrink-0">
                  {ev.verified ? <ShieldCheck size={14} className="text-success" /> : <ShieldX size={14} className="text-warning" />}
                </div>
                <div className="min-w-0 flex-1">
                  <div className="text-sm font-medium text-text-primary">{ev.event_type}</div>
                  <div className="truncate font-mono text-[11px] text-text-secondary">{ev.target}</div>
                  <div className="mt-1 flex gap-4 text-[11px] text-text-tertiary">
                    <span>Decision: {ev.decision ?? "recorded"}</span>
                    <span>Verified: {ev.verified ? "yes" : "not checked"}</span>
                  </div>
                </div>
              </div>
            ))
          )}
        </div>
      </section>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <section className="rounded-card border border-border bg-surface p-5">
          <SectionHeader title="Guarantees" />
          <ul className="space-y-3">
            {secretless?.guarantees.map((g, i) => (
              <li key={i} className="flex items-start gap-2 text-[13px] leading-relaxed text-text-secondary">
                <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-success" />
                {g}
              </li>
            ))}
          </ul>
        </section>
        <section className="rounded-card border border-border bg-surface p-5">
          <SectionHeader title="Limitations" />
          <ul className="space-y-3">
            {secretless?.limitations.map((l, i) => (
              <li key={i} className="flex items-start gap-2 text-[13px] leading-relaxed text-text-secondary">
                <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-warning" />
                {l}
              </li>
            ))}
          </ul>
        </section>
      </div>
    </div>
  );
}

export default function SecretlessPage() {
  return (
    <ErrorBoundary>
      <WorkspaceOnlyGate><SecretlessContent /></WorkspaceOnlyGate>
    </ErrorBoundary>
  );
}
