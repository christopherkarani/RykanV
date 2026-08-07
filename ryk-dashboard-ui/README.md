# ryk Dashboard UI

A Vercel-style dashboard for the ryk local guardrail runtime. Built with Next.js 15, TypeScript, and Tailwind CSS.

## Prerequisites

- Node.js 22.6+
- The ryk backend must be running on `http://127.0.0.1:7742`

## Installation

```bash
cd ryk-dashboard-ui
npm install
```

## Development

```bash
npm run dev
```

The development server starts on `http://localhost:3000`. API paths are same-origin in production; use the ryk-served static build for end-to-end API work.

> **Note:** The ryk backend (`ryk dashboard`) must be running on `localhost:7742` for the dashboard to load data.

## Build

```bash
npm run build
```

The build exports static files to `dist/`. ryk packages and serves that directory with its authenticated local dashboard server; `next start` is not used with this export configuration.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘K` / `Ctrl+K` | Open command palette |
| `Escape` | Close command palette, modals, or expanded output drawer |
| `?` | Show keyboard shortcuts (planned) |

## Browser Requirements

- Chrome 90+
- Firefox 88+
- Safari 14+
- Edge 90+

## Architecture

- **Next.js 15 App Router** with client-side data fetching
- **Tailwind CSS** with custom semantic color tokens
- **Geist Sans / Mono** fonts
- **Lucide React** icons
- **Shiki** for syntax highlighting (dynamic import)
- Dark mode only
