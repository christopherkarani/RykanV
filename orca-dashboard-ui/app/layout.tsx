import type { Metadata } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import "./globals.css";
import ClientProviders from "./components/ClientProviders";
import TopNav from "./components/TopNav";
import OutputDrawer from "./components/OutputDrawer";
import ToastRegion from "./components/ToastRegion";

export const metadata: Metadata = {
  title: "ryk Dashboard",
  description: "Local guardrail dashboard",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`dark ${GeistSans.variable} ${GeistMono.variable}`}>
      <head>
        <meta name="orca-dashboard-token" content="__ORCA_DASHBOARD_TOKEN__" />
      </head>
      <body className="font-sans antialiased">
        <ClientProviders>
          <a
            href="#main"
            className="fixed left-4 top-3 z-nav -translate-y-40 rounded bg-text-primary px-4 py-2.5 text-sm font-medium text-background transition focus-visible:translate-y-0"
          >
            Skip to main content
          </a>
          <TopNav />
          <main id="main" className="mx-auto max-w-7xl px-4 pb-40 pt-20 md:px-6 md:pb-56">
            {children}
          </main>
          <OutputDrawer />
          <ToastRegion />
        </ClientProviders>
      </body>
    </html>
  );
}
