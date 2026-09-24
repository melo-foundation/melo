import { useState, useEffect } from "react";
import { darkThemes, lightThemes, applyTheme } from "./themes";
import type { LandingTheme } from "./themes";
import { ScrollRevealProvider } from "./ScrollRevealContext";
import { BackgroundCanvas } from "./BackgroundCanvas";
import { Nav } from "./components/Nav";
import { Hero } from "./components/Hero";
import { Features } from "./components/Features";
import DemoSection from "./demo/DemoSection";
import { DownloadSection } from "./components/DownloadSection";
import { Footer } from "./components/Footer";

function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(() => window.matchMedia(query).matches);
  useEffect(() => {
    const mql = window.matchMedia(query);
    const handler = (e: MediaQueryListEvent) => setMatches(e.matches);
    mql.addEventListener("change", handler);
    return () => mql.removeEventListener("change", handler);
  }, [query]);
  return matches;
}

export function App() {
  const prefersDark = useMediaQuery("(prefers-color-scheme: dark)");
  const [theme, setTheme] = useState<LandingTheme>(() => {
    const t = prefersDark ? darkThemes[0] : lightThemes[0];
    applyTheme(t);
    return t;
  });
  const [demoActive, setDemoActive] = useState(false);

  useEffect(() => {
    setTheme(prefersDark ? darkThemes[0] : lightThemes[0]);
  }, [prefersDark]);

  useEffect(() => {
    applyTheme(theme);
  }, [theme]);

  return (
    <ScrollRevealProvider>
      <BackgroundCanvas accent={theme.palette.accent} />
      <div className="app-root">
        <Nav demoActive={demoActive} />
        <main>
          <Hero />
          <Features />
          <DownloadSection />
          <DemoSection currentTheme={theme} onThemeChange={setTheme} onActivate={() => setDemoActive(true)} onClose={() => setDemoActive(false)} />
        </main>
        <Footer />
      </div>
    </ScrollRevealProvider>
  );
}
