"use client";

import { ToastProvider } from "../hooks/useToast";
import { OutputProvider } from "../hooks/useCommandOutput";
import { DashboardModeProvider } from "../lib/dashboard-mode";

export default function ClientProviders({ children }: { children: React.ReactNode }) {
  return (
    <DashboardModeProvider>
      <ToastProvider>
        <OutputProvider>{children}</OutputProvider>
      </ToastProvider>
    </DashboardModeProvider>
  );
}
