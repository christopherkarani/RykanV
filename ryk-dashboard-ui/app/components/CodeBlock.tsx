"use client";

import { useEffect, useState } from "react";
import { Copy, Check } from "lucide-react";

interface CodeBlockProps {
  code: string;
  lang?: string;
  filename?: string;
}

export default function CodeBlock({ code, lang = "yaml", filename }: CodeBlockProps) {
  const [highlighted, setHighlighted] = useState<string>("");
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      const { codeToHtml } = await import("shiki");
      const html = await codeToHtml(code, {
        lang,
        theme: "github-dark",
      });
      if (!cancelled) setHighlighted(html);
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [code, lang]);

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(code);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // noop
    }
  };

  return (
    <div className="relative rounded-card border border-border bg-[#0a0a0a]"
    >
      {filename && (
        <div className="flex items-center justify-between border-b border-border px-4 py-2">
          <span className="text-xs text-text-tertiary">{filename}</span>
        </div>
      )}
      <button
        onClick={handleCopy}
        className="absolute right-3 top-3 rounded p-1.5 text-text-tertiary hover:text-text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
        aria-label="Copy to clipboard"
        title="Copy to clipboard"
      >
        {copied ? <Check size={14} className="text-success" /> : <Copy size={14} />}
      </button>
      {highlighted ? (
        <div
          className="overflow-auto p-4 text-sm"
          dangerouslySetInnerHTML={{ __html: highlighted }}
        />
      ) : (
        <pre className="p-4 font-mono text-sm text-text-primary">{code}</pre>
      )}
    </div>
  );
}
