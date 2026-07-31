import type { Config } from "tailwindcss";

const config: Config = {
  darkMode: "class",
  content: [
    "./app/**/*.{js,ts,jsx,tsx,mdx}",
    "./components/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        background: "#0a0a0a",
        "background-pure": "#000000",
        surface: "#111111",
        "surface-elevated": "#171717",
        "surface-hover": "rgba(255,255,255,0.04)",
        "surface-active": "rgba(255,255,255,0.07)",
        border: "rgba(255,255,255,0.08)",
        "border-strong": "rgba(255,255,255,0.14)",
        "text-primary": "#ededed",
        "text-secondary": "#a1a1a1",
        "text-tertiary": "#737373",
        accent: "#0070f3",
        "accent-hover": "#1a7ff7",
        success: "#50e3c2",
        "success-muted": "rgba(80,227,194,0.10)",
        error: "#ff4d4d",
        "error-muted": "rgba(255,77,77,0.10)",
        warning: "#f5a623",
        "warning-muted": "rgba(245,166,35,0.10)",
      },
      fontFamily: {
        sans: ["var(--font-geist-sans)", "ui-sans-serif", "system-ui", "sans-serif"],
        mono: ["var(--font-geist-mono)", "ui-monospace", "monospace"],
      },
      borderRadius: {
        card: "8px",
        code: "4px",
        pill: "9999px",
      },
      spacing: {
        nav: "56px",
        "drawer-peek": "48px",
      },
      zIndex: {
        nav: "50",
        drawer: "45",
        toast: "60",
        modal: "55",
      },
      transitionDuration: {
        micro: "150ms",
        standard: "200ms",
        complex: "300ms",
      },
      keyframes: {
        shimmer: {
          "0%": { backgroundPosition: "-200% 0" },
          "100%": { backgroundPosition: "200% 0" },
        },
      },
      animation: {
        shimmer: "shimmer 1.5s ease-in-out infinite",
      },
    },
  },
  plugins: [],
};

export default config;
