"use client";

import { Component, type ReactNode } from "react";

interface Props {
  children: ReactNode;
  fallback?: ReactNode;
}

interface State {
  hasError: boolean;
}

export default class ErrorBoundary extends Component<Props, State> {
  state: State = { hasError: false };

  static getDerivedStateFromError(): State {
    return { hasError: true };
  }

  render() {
    if (this.state.hasError) {
      return (
        this.props.fallback ?? (
          <div className="flex flex-col items-center justify-center gap-4 rounded-card border border-border bg-surface p-8 text-center"
          >
            <h2 className="text-lg font-semibold text-text-primary">Something went wrong</h2>
            <p className="text-sm text-text-secondary">An error occurred while rendering this view.</p>
            <button
              onClick={() => this.setState({ hasError: false })}
              className="rounded bg-accent px-4 py-2 text-sm font-medium text-white hover:brightness-110"
            >
              Retry
            </button>
          </div>
        )
      );
    }
    return this.props.children;
  }
}
