"use client";

import { useEffect, useState, useCallback } from "react";
import { fetchStatus, runAction } from "../lib/api";
import type { StatusResponse } from "../lib/types";
import { useToast } from "../hooks/useToast";
import { useCommandOutput } from "../hooks/useCommandOutput";
import ErrorBoundary from "../components/ErrorBoundary";
import PageHeader from "../components/PageHeader";
import SectionHeader from "../components/SectionHeader";
import SkeletonCard from "../components/SkeletonCard";
import StatusBadge from "../components/StatusBadge";
import { Copy, Check, Plug, Stethoscope, Terminal } from "lucide-react";

function IntegrationsContent() {
  const [data, setData] = useState<StatusResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [copiedCmd, setCopiedCmd] = useState<string | null>(null);
  const { enqueue } = useToast();
  const { append, expand } = useCommandOutput();

  const load = useCallback(async () => {
    try {
      const status = await fetchStatus();
      setData(status);
    } catch (err) {
      enqueue(err instanceof Error ? err.message : "Failed to load integrations", "error");
    } finally {
      setLoading(false);
    }
  }, [enqueue]);

  useEffect(() => {
    load();
  }, [load]);

  const handleCopy = async (cmd: string) => {
    try {
      await navigator.clipboard.writeText(cmd);
      setCopiedCmd(cmd);
      setTimeout(() => setCopiedCmd(null), 2000);
      enqueue("Command copied", "success");
    } catch {
      enqueue("Copy failed", "error");
    }
  };

  const handleDoctor = async (pluginId: string) => {
    expand();
    append(`$ ryk plugin doctor ${pluginId}`);
    try {
      const result = await runAction(`${pluginId}-doctor`);
      const output = [
        `$ ryk plugin doctor ${pluginId}`,
        `exit ${result.exit_code}`,
        result.stdout || "",
        result.stderr ? `stderr:\n${result.stderr}` : "",
      ]
        .filter(Boolean)
        .join("\n\n");
      append(output);
      enqueue(result.ok ? "Doctor completed" : "Doctor returned non-zero", result.ok ? "success" : "error");
    } catch (err) {
      append(err instanceof Error ? err.message : "Doctor failed");
      enqueue(err instanceof Error ? err.message : "Doctor failed", "error");
    }
  };

  if (loading) {
    return (
      <div className="space-y-8">
        <PageHeader title="Integrations" />
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {Array.from({ length: 2 }).map((_, i) => (
            <SkeletonCard key={i} />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-8">
      <PageHeader title="Integrations" subtitle="Plugin setup, status, and doctor commands." />
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {data?.plugins.map((plugin) => {
          const detected = plugin.host_detected && plugin.integration_present;
          return (
            <div
              key={plugin.id}
              className="flex flex-col rounded-card border border-border bg-surface p-5 transition hover:border-border-strong"
            >
              <div className="flex items-start justify-between">
                <div className="flex items-center gap-3">
                  <div className="flex h-9 w-9 items-center justify-center rounded-lg border border-border bg-surface-elevated/60">
                    <Plug size={16} className="text-text-tertiary" />
                  </div>
                  <div>
                    <h2 className="text-sm font-semibold text-text-primary">{plugin.label}</h2>
                    <StatusBadge variant={detected ? "success" : "warning"} dot className="mt-1">
                      {detected ? "detected" : "needs setup"}
                    </StatusBadge>
                  </div>
                </div>
              </div>

              <div className="mt-5 grid grid-cols-2 gap-3 text-[11px]">
                <div>
                  <span className="block font-medium uppercase tracking-wider text-text-tertiary">Host binary</span>
                  <span className="mt-0.5 block text-text-secondary">
                    {plugin.host_detected ? "found in PATH" : "not found"}
                  </span>
                </div>
                <div>
                  <span className="block font-medium uppercase tracking-wider text-text-tertiary">ryk integration</span>
                  <span className="mt-0.5 block text-text-secondary">
                    {plugin.integration_present ? "present in repo" : "not found"}
                  </span>
                </div>
              </div>

              <div className="mt-4 space-y-2">
                {plugin.setup_commands.map((cmd) => (
                  <div
                    key={cmd}
                    className="flex items-center gap-2 rounded-lg border border-border bg-surface-elevated/60 px-3 py-2"
                  >
                    <Terminal size={12} className="shrink-0 text-text-tertiary" />
                    <code className="min-w-0 flex-1 truncate font-mono text-[11px] text-text-secondary">
                      {cmd}
                    </code>
                    <button
                      onClick={() => handleCopy(cmd)}
                      className="shrink-0 rounded p-1 text-text-tertiary transition hover:text-text-primary"
                      aria-label="Copy command"
                    >
                      {copiedCmd === cmd ? (
                        <Check size={13} className="text-success" />
                      ) : (
                        <Copy size={13} />
                      )}
                    </button>
                  </div>
                ))}
              </div>

              <button
                onClick={() => handleDoctor(plugin.id)}
                className="mt-4 flex min-h-[40px] items-center justify-center gap-2 rounded-md border border-border bg-transparent py-2 text-[13px] font-medium text-text-secondary transition hover:bg-surface-hover hover:text-text-primary active:scale-[0.98]"
              >
                <Stethoscope size={14} />
                <span>Run {plugin.label} doctor</span>
              </button>
            </div>
          );
        })}
      </div>
    </div>
  );
}

export default function IntegrationsPage() {
  return (
    <ErrorBoundary>
      <IntegrationsContent />
    </ErrorBoundary>
  );
}
