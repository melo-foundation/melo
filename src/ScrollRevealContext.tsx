import { createContext, useContext, useState } from "react";
import type { AnimationStyle } from "./useScrollReveal";

interface ScrollRevealContextValue {
  enterStyle: AnimationStyle;
  leaveStyle: AnimationStyle;
  setEnterStyle: (s: AnimationStyle) => void;
  setLeaveStyle: (s: AnimationStyle) => void;
}

const Ctx = createContext<ScrollRevealContextValue>({
  enterStyle: "fade-up",
  leaveStyle: "fade",
  setEnterStyle: () => {},
  setLeaveStyle: () => {},
});

export function ScrollRevealProvider({ children }: { children: React.ReactNode }) {
  const [enterStyle, setEnterStyle] = useState<AnimationStyle>("drop");
  const [leaveStyle, setLeaveStyle] = useState<AnimationStyle>("drop");
  return (
    <Ctx.Provider value={{ enterStyle, leaveStyle, setEnterStyle, setLeaveStyle }}>
      {children}
    </Ctx.Provider>
  );
}

export function useScrollRevealStyle() {
  return useContext(Ctx);
}
