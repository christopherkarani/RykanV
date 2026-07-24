import type {
  StatusResponse,
  PolicyResponse,
  PolicySaveBody,
  PolicySaveResult,
  PolicyInitBody,
  ActionBody,
  ActionResult,
} from "./types.ts";

function getToken(): string {
  if (typeof document === "undefined") return "";
  const meta = document.querySelector('meta[name="orca-dashboard-token"]') as HTMLMetaElement | null;
  return meta?.content ?? "";
}

async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(path, { headers: { Accept: "application/json" } });
  if (!res.ok) throw new Error(`${path} returned ${res.status}`);
  return res.json() as Promise<T>;
}

async function postJson<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(path, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "X-Ryk-Dashboard-Token": getToken(),
      "X-Orca-Dashboard-Token": getToken(),
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    if (res.status === 403) throw new Error("Session expired. Please refresh the page.");
    throw new Error(`${path} returned ${res.status}`);
  }
  return res.json() as Promise<T>;
}

export function fetchStatus(): Promise<StatusResponse> {
  return getJson<StatusResponse>("/api/status");
}

export function fetchPolicy(): Promise<PolicyResponse> {
  return getJson<PolicyResponse>("/api/policy");
}

export function savePolicy(text: string): Promise<PolicySaveResult> {
  return postJson<PolicySaveResult>("/api/policy", { text } as PolicySaveBody);
}

export function initPreset(preset: string, force = false): Promise<PolicySaveResult> {
  return postJson<PolicySaveResult>("/api/policy/init", { preset, force } as PolicyInitBody);
}

export function runAction(action: string): Promise<ActionResult> {
  return postJson<ActionResult>("/api/actions", { action } as ActionBody);
}
