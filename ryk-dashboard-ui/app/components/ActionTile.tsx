"use client";

import { Loader2 } from "lucide-react";
import {
  Stethoscope,
  ShieldCheck,
  KeyRound,
  Github,
  Wifi,
  FileText,
  RotateCcw,
  FileBarChart,
  GitBranch,
  Ban,
  BadgeCheck,
  Plug,
  MessageSquare,
  XCircle,
  type LucideIcon,
} from "lucide-react";

const iconMap: Record<string, LucideIcon> = {
  Stethoscope,
  ShieldCheck,
  KeyRound,
  Github,
  Wifi,
  FileText,
  RotateCcw,
  FileBarChart,
  GitBranch,
  Ban,
  BadgeCheck,
  Plug,
  MessageSquare,
  XCircle,
};

// Map action IDs to icon names
const actionIconMap: Record<string, string> = {
  doctor: "Stethoscope",
  "policy-check": "ShieldCheck",
  "credentials-check": "KeyRound",
  "credentials-check-github": "Github",
  "proxy-smoke": "Wifi",
  "policy-explain-github": "FileText",
  "replay-last": "RotateCcw",
  "report-last": "FileBarChart",
  "ci-check": "GitBranch",
  "demo-blocked-action": "Ban",
  "openclaw-doctor": "Plug",
  "hermes-doctor": "MessageSquare",
  "replay-denied": "XCircle",
  "suggest-allowlist": "ShieldCheck",
  "allowlist-list": "FileText",
};

interface ActionTileProps {
  id: string;
  label: string;
  iconName?: string;
  onClick?: () => void;
  loading?: boolean;
}

export default function ActionTile({ id, label, iconName, onClick, loading }: ActionTileProps) {
  const resolvedIcon = iconName ?? actionIconMap[id] ?? "Stethoscope";
  const Icon = iconMap[resolvedIcon] ?? Stethoscope;

  return (
    <button
      onClick={onClick}
      disabled={loading}
      className="group flex min-h-[72px] w-full flex-col items-center justify-center gap-2 rounded-card border border-border bg-surface px-3 py-3.5 text-center transition-all duration-micro hover:border-border-strong hover:bg-surface-hover active:scale-[0.97] disabled:opacity-50"
      aria-label={label}
    >
      {loading ? (
        <Loader2 size={18} className="animate-spin text-accent" />
      ) : (
        <Icon size={18} className="text-text-tertiary transition-colors group-hover:text-text-secondary" strokeWidth={1.5} />
      )}
      <span className="text-[13px] font-medium leading-snug text-text-primary">{label}</span>
    </button>
  );
}
