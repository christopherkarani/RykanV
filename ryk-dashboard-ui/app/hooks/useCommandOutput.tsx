"use client";

import { createContext, useContext, useState, useCallback, useRef, type ReactNode } from "react";

interface OutputContextValue {
  lines: string[];
  isOpen: boolean;
  isExpanded: boolean;
  append: (text: string) => void;
  clear: () => void;
  open: () => void;
  close: () => void;
  toggle: () => void;
  expand: () => void;
  scrollRef: React.RefObject<HTMLPreElement | null>;
}

const OutputContext = createContext<OutputContextValue | null>(null);

export function OutputProvider({ children }: { children: ReactNode }) {
  const [lines, setLines] = useState<string[]>([]);
  const [isOpen, setIsOpen] = useState(true);
  const [isExpanded, setIsExpanded] = useState(false);
  const scrollRef = useRef<HTMLPreElement | null>(null);

  const append = useCallback((text: string) => {
    setLines((prev) => [...prev, text]);
    setTimeout(() => {
      if (scrollRef.current) {
        scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
      }
    }, 0);
  }, []);

  const clear = useCallback(() => {
    setLines([]);
  }, []);

  const open = useCallback(() => {
    setIsOpen(true);
  }, []);

  const close = useCallback(() => {
    setIsOpen(false);
    setIsExpanded(false);
  }, []);

  const toggle = useCallback(() => {
    setIsOpen((prev) => !prev);
  }, []);

  const expand = useCallback(() => {
    setIsOpen(true);
    setIsExpanded(true);
  }, []);

  return (
    <OutputContext.Provider
      value={{ lines, isOpen, isExpanded, append, clear, open, close, toggle, expand, scrollRef }}
    >
      {children}
    </OutputContext.Provider>
  );
}

export function useCommandOutput() {
  const ctx = useContext(OutputContext);
  if (!ctx) throw new Error("useCommandOutput must be used within OutputProvider");
  return ctx;
}
