"use client";

import { useEffect, useState, useCallback } from "react";
import { fetchPolicy, savePolicy, initPreset } from "../lib/api";
import type { PolicyResponse, PresetInfo } from "../lib/types";
import { useToast } from "../hooks/useToast";
import ErrorBoundary from "../components/ErrorBoundary";
import PageHeader from "../components/PageHeader";
import SectionHeader from "../components/SectionHeader";
import SkeletonCard from "../components/SkeletonCard";
import ConfirmModal from "../components/ConfirmModal";
import StatusBadge from "../components/StatusBadge";
import { Loader2, FileText, AlertTriangle, ShieldX } from "lucide-react";
import { WorkspaceOnlyGate } from "../lib/dashboard-mode";

function PolicyContent() {
  const [data, setData] = useState<PolicyResponse | null>(null);
  const [text, setText] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [confirmPreset, setConfirmPreset] = useState<PresetInfo | null>(null);
  const { enqueue } = useToast();

  const load = useCallback(async () => {
    try {
      const policy = await fetchPolicy();
      setData(policy);
      setText(policy.text ?? "");
      setDirty(false);
    } catch (err) {
      enqueue(err instanceof Error ? err.message : "Failed to load policy", "error");
    } finally {
      setLoading(false);
    }
  }, [enqueue]);

  useEffect(() => {
    load();
  }, [load]);

  useEffect(() => {
    setDirty(text !== (data?.text ?? ""));
  }, [text, data]);

  const handleSave = async () => {
    setSaving(true);
    try {
      const result = await savePolicy(text);
      if (result.ok) {
        enqueue("Policy saved", "success");
        setDirty(false);
        setData((prev) => (prev ? { ...prev, text } : prev));
      } else {
        enqueue(`Policy not saved: ${result.error ?? "unknown error"}`, "error");
      }
    } catch (err) {
      enqueue(err instanceof Error ? err.message : "Save failed", "error");
    } finally {
      setSaving(false);
    }
  };

  const handlePreset = async (preset: PresetInfo) => {
    if (dirty) {
      setConfirmPreset(preset);
      return;
    }
    await applyPreset(preset);
  };

  const applyPreset = async (preset: PresetInfo) => {
    try {
      const result = await initPreset(preset.name, false);
      if (result.ok) {
        enqueue(`Initialized ${preset.name}`, "success");
        load();
      } else if (result.error === "PolicyAlreadyExists") {
        enqueue("Policy already exists. Save explicit edits from the editor to replace it.", "error");
      } else {
        enqueue(`Preset failed: ${result.error ?? "unknown error"}`, "error");
      }
    } catch (err) {
      enqueue(err instanceof Error ? err.message : "Preset failed", "error");
    }
  };

  const lineCount = text.split("\n").length;

  return (
    <div className="space-y-10">
      <PageHeader
        title="Policy"
        subtitle="Edit, validate, and save your .ryk/policy.yaml."
        action={
          dirty ? (
            <StatusBadge variant="warning" dot>
              Unsaved changes
            </StatusBadge>
          ) : null
        }
      />

      <section className="rounded-card border border-border bg-surface p-5">
        <div className="mb-4 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h2 className="text-base font-semibold text-text-primary">.ryk/policy.yaml</h2>
            <p className="mt-0.5 text-xs text-text-tertiary">Saved only after ryk validates it</p>
          </div>
          <button
            onClick={handleSave}
            disabled={saving || !dirty}
            className="flex min-h-[40px] items-center gap-2 self-start rounded-md bg-accent px-4 py-2 text-[13px] font-medium text-white shadow-sm shadow-accent/20 transition-all hover:bg-accent-hover disabled:opacity-40 active:scale-[0.97]"
          >
            {saving && <Loader2 size={15} className="animate-spin" />}
            <span>Validate and save</span>
          </button>
        </div>

        <label htmlFor="policyText" className="sr-only">Policy source</label>
        <div className="flex overflow-hidden rounded-card border border-border bg-[#0a0a0a]">
          <div className="select-none border-r border-border bg-surface-elevated/80 px-3 py-4 text-right font-mono text-[11px] leading-6 text-text-tertiary">
            {Array.from({ length: Math.max(lineCount, 1) }).map((_, i) => (
              <div key={i} className="h-6">{i + 1}</div>
            ))}
          </div>
          <textarea
            id="policyText"
            value={text}
            onChange={(e) => setText(e.target.value)}
            spellCheck={false}
            className="min-h-[520px] flex-1 resize-y bg-[#0a0a0a] p-4 font-mono text-[13px] leading-6 text-text-primary outline-none"
          />
        </div>
        <p className="mt-3 text-[11px] leading-relaxed text-text-tertiary">
          Use presets to initialize a policy. Detailed edits should be kept in source form.
          ryk validates all YAML server-side before saving.
        </p>
      </section>

      <section>
        <SectionHeader title="Presets" subtitle="Initialize locally" />
        {loading ? (
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {Array.from({ length: 3 }).map((_, i) => (
              <SkeletonCard key={i} />
            ))}
          </div>
        ) : !data ? (
          <div className="flex flex-col items-center gap-3 rounded-card border border-dashed border-border bg-surface/50 p-8 text-center">
            <div className="flex h-10 w-10 items-center justify-center rounded-full bg-surface-elevated">
              <ShieldX size={18} className="text-warning" />
            </div>
            <div>
              <p className="text-sm font-medium text-text-secondary">Unable to load presets</p>
              <p className="mt-0.5 text-xs text-text-tertiary">Make sure ryk is running and try again.</p>
            </div>
          </div>
        ) : (
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {data.presets.map((preset) => (
              <div
                key={preset.name}
                className="flex flex-col justify-between rounded-card border border-border bg-surface p-5 transition hover:border-border-strong"
              >
                <div>
                  <div className="flex items-center gap-2">
                    <FileText size={15} className="text-text-tertiary" />
                    <h3 className="text-sm font-medium text-text-primary">{preset.name}</h3>
                  </div>
                  <p className="mt-2 text-[13px] leading-relaxed text-text-secondary">
                    {preset.experimental ? preset.warning : "Stable local starter policy."}
                  </p>
                </div>
                <button
                  onClick={() => handlePreset(preset)}
                  className="mt-4 w-full rounded-md border border-border bg-transparent py-2 text-[13px] font-medium text-text-secondary transition hover:bg-surface-hover hover:text-text-primary active:scale-[0.98]"
                >
                  Use preset
                </button>
              </div>
            ))}
          </div>
        )}
      </section>

      <ConfirmModal
        open={!!confirmPreset}
        title="Unsaved changes"
        message="You have unsaved changes in the policy editor. Using a preset will overwrite them. Continue?"
        confirmLabel="Overwrite"
        onConfirm={() => {
          if (confirmPreset) {
            applyPreset(confirmPreset);
            setConfirmPreset(null);
          }
        }}
        onCancel={() => setConfirmPreset(null)}
      />
    </div>
  );
}

export default function PolicyPage() {
  return (
    <ErrorBoundary>
      <WorkspaceOnlyGate><PolicyContent /></WorkspaceOnlyGate>
    </ErrorBoundary>
  );
}
