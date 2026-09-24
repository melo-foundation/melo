import { useRef, useEffect } from "react";
import { useScrollRevealStyle } from "../ScrollRevealContext";
import { getManager } from "../useScrollReveal";

interface Props {
  children: React.ReactNode;
  className?: string;
}

export function ScrollReveal({ children, className }: Props) {
  const ref = useRef<HTMLDivElement>(null);
  const { enterStyle, leaveStyle } = useScrollRevealStyle();

  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    const mgr = getManager();
    mgr.register(el, enterStyle, leaveStyle);
    return () => mgr.unregister(el);
  }, []); // register once on mount

  // Update styles when selectors change
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    getManager().update(el, enterStyle, leaveStyle);
  }, [enterStyle, leaveStyle]);

  return (
    <div ref={ref} className={className}>
      {children}
    </div>
  );
}
