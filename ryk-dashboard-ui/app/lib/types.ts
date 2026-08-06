export interface RykMeta {
  installed: boolean;
  version: string;
  workspace_root: string | null;
}

export interface PolicySummary {
  path: string;
  exists: boolean;
  valid: boolean;
  mode: string | null;
  error: string | null;
}

export interface ActiveBroker {
  id: string;
  label: string;
  kind: string;
  status: string;
  stores_raw_secrets: boolean;
  injects_raw_credentials: boolean;
  description: string;
}

export interface CredentialRef {
  name: string;
  broker: string | null;
  ref: string;
  raw_value: null;
}

export interface BrokerCheck {
  broker: string;
  kind: string;
  status: string;
  message: string;
}

export interface ProxyBackend {
  status: string;
  bind: string;
  https_visibility: string;
  method_path_visibility: string;
  backend: string;
}

export interface SupportedBroker {
  id: string;
  label: string;
  status: string;
  stores_raw_secrets: boolean;
  notes: string;
}

export interface Capability {
  label: string;
  state: "active" | "limited" | "unavailable";
  detail: string;
}

export interface AuditEvent {
  session_id: string;
  timestamp: string;
  event_type: string;
  target: string;
  decision: string | null;
  verified: boolean;
}

export interface SecretlessRuntime {
  available: boolean;
  active_broker: ActiveBroker;
  credential_refs: CredentialRef[];
  broker_checks: BrokerCheck[];
  recent_audit_events: AuditEvent[];
  proxy_backend: ProxyBackend;
  supported_brokers: SupportedBroker[];
  capabilities: Capability[];
  guarantees: string[];
  limitations: string[];
  run_command: string;
  verify_commands: string[];
  service_policy_template: string;
}

export interface License {
  tier: string;
  verified: boolean;
  report_export: boolean;
  error: string | null;
}

export interface CiCheckItem {
  name: string;
  status: "ok" | "warn" | "error";
  message: string;
}

export interface CiReadiness {
  ok: boolean;
  error: string | null;
  checks: CiCheckItem[];
}

export interface Plugin {
  id: string;
  label: string;
  host_detected: boolean;
  integration_present: boolean;
  doctor_command: string;
  setup_commands: string[];
}

export interface Session {
  id: string;
  workspace_root: string;
  host: string | null;
  timestamp: string;
  command: string | null;
  policy: string | null;
  status: string | null;
  latest_decision: string | null;
  feed_only: boolean;
  denied_count: number;
  verified: boolean;
  error?: string;
}

export interface BlockedAction {
  session_id: string;
  workspace_root: string;
  host: string | null;
  timestamp: string;
  event_type: string;
  target: string;
  decision: string | null;
  verified: boolean;
  rule: string | null;
  reason: string | null;
  raw: Record<string, unknown>;
}

export interface QuickAction {
  id: string;
  command: string;
}

export interface StatusResponse {
  mode: "machine" | "workspace";
  workspace_count: number;
  workspaces: Array<{ root: string; last_seen_at: string; last_host: string | null; policy_present: boolean }>;
  ryk: RykMeta;
  policy: PolicySummary | null;
  secretless_runtime: SecretlessRuntime | null;
  license: License;
  ci_readiness: CiReadiness | null;
  plugins: Plugin[];
  sessions: Session[];
  blocked_actions: BlockedAction[];
  feed_health: "healthy" | "degraded" | { status: "healthy" | "degraded"; skipped_lines: number };
  feed_skipped_lines?: number;
  quick_actions: QuickAction[];
}

export function sessionKey(session: Pick<Session, "id" | "workspace_root">): string {
  return `${session.workspace_root}\u0000${session.id}`;
}

export function feedHealthMessage(
  status: Pick<StatusResponse, "feed_health" | "feed_skipped_lines">,
): string | null {
  const health = typeof status.feed_health === "string" ? status.feed_health : status.feed_health.status;
  const count = status.feed_skipped_lines ?? (typeof status.feed_health === "string" ? 0 : status.feed_health.skipped_lines);
  if (health !== "degraded" && count === 0) return null;
  return `Activity feed is degraded. ryk skipped ${count} malformed ${count === 1 ? "line" : "lines"}; valid activity is still shown.`;
}

export interface PolicyResponse {
  summary: PolicySummary;
  presets: PresetInfo[];
  text: string | null;
}

export interface PresetInfo {
  name: string;
  experimental: boolean;
  warning: string;
}

export interface PolicySaveBody {
  text: string;
}

export interface PolicySaveResult {
  ok: boolean;
  error?: string;
}

export interface PolicyInitBody {
  preset: string;
  force: boolean;
}

export interface ActionBody {
  action: string;
}

export interface ActionResult {
  ok: boolean;
  exit_code: number;
  stdout: string;
  stderr: string;
}
