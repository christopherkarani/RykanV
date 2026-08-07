"use client";

import { useEffect, useCallback, useRef } from "react";

export function useKeyboardShortcut(
  key: string,
  callback: () => void,
  options?: { meta?: boolean; ctrl?: boolean; preventDefault?: boolean }
) {
  const metaRef = useRef(options?.meta ?? false);
  const ctrlRef = useRef(options?.ctrl ?? false);
  const preventDefaultRef = useRef(options?.preventDefault ?? true);

  useEffect(() => {
    metaRef.current = options?.meta ?? false;
    ctrlRef.current = options?.ctrl ?? false;
    preventDefaultRef.current = options?.preventDefault ?? true;
  }, [options?.meta, options?.ctrl, options?.preventDefault]);

  const handle = useCallback(
    (e: KeyboardEvent) => {
      const matchKey = e.key.toLowerCase() === key.toLowerCase();
      const matchMeta = metaRef.current ? e.metaKey : true;
      const matchCtrl = ctrlRef.current ? e.ctrlKey : true;
      if (matchKey && matchMeta && matchCtrl) {
        if (preventDefaultRef.current !== false) e.preventDefault();
        callback();
      }
    },
    [key, callback]
  );

  useEffect(() => {
    window.addEventListener("keydown", handle);
    return () => window.removeEventListener("keydown", handle);
  }, [handle]);
}
