"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { isNavTabActive, NAV_TABS } from "../lib/nav";

export default function MobileBottomNav() {
  const pathname = usePathname();

  return (
    <nav
      className="fixed inset-x-0 bottom-0 z-nav border-t border-border bg-background/95 pb-[env(safe-area-inset-bottom,0px)] backdrop-blur-xl md:hidden"
      aria-label="Mobile primary"
    >
      <div className="mx-auto flex h-14 max-w-lg items-stretch justify-around px-1">
        {NAV_TABS.map((tab) => {
          const Icon = tab.icon;
          const isActive = isNavTabActive(pathname, tab.href);

          return (
            <Link
              key={tab.id}
              href={tab.href}
              aria-label={tab.label}
              aria-current={isActive ? "page" : undefined}
              className={`flex min-h-[44px] min-w-[44px] flex-1 flex-col items-center justify-center gap-0.5 rounded-md px-1 py-1 text-[10px] font-medium transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent ${
                isActive ? "text-accent" : "text-text-tertiary active:text-text-secondary"
              }`}
            >
              <Icon size={18} strokeWidth={isActive ? 2 : 1.5} aria-hidden="true" />
              <span aria-hidden="true" className="max-w-full truncate">
                {tab.shortLabel}
              </span>
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
