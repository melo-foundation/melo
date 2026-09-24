import { useState, useEffect, useCallback } from "react";
import { MeloLockup, GitHubIcon, DiscordIcon } from "./icons";
// import { useScrollRevealStyle } from "../ScrollRevealContext";
// import { animationStyles } from "../useScrollReveal";

const GITHUB_URL = "https://github.com/melo-foundation/melo";
const DISCORD_URL = "https://discord.gg/T2jHMX6AcG";

const links = [
  { label: "Home", href: "#" },
  { label: "Features", href: "#features" },
  { label: "Download", href: "#download" },
  { label: "Demo", href: "#demo" },
];

export function Nav({ demoActive }: { demoActive?: boolean }) {
  const [scrolled, setScrolled] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  // const { enterStyle, leaveStyle, setEnterStyle, setLeaveStyle } = useScrollRevealStyle();

  useEffect(() => {
    const handler = () => setScrolled(window.scrollY > 20);
    window.addEventListener("scroll", handler, { passive: true });
    return () => window.removeEventListener("scroll", handler);
  }, []);

  const smoothScroll = useCallback((e: React.MouseEvent<HTMLAnchorElement>, href: string) => {
    e.preventDefault();
    setMenuOpen(false);
    if (href === "#") {
      window.scrollTo({ top: 0, behavior: "smooth" });
      return;
    }
    const el = document.querySelector(href);
    if (el) {
      const rect = el.getBoundingClientRect();
      const offset = href === "#download" ? 40 : 0;
      const top = rect.top + window.scrollY - (window.innerHeight - rect.height) / 2 + offset;
      window.scrollTo({ top: Math.max(0, top), behavior: "smooth" });
    }
  }, []);

  return (
    <nav className={`nav ${scrolled ? "nav--scrolled" : ""}`}>
      <div className="nav__inner container">
        <a href="#" className="nav__logo" onClick={(e) => {
          e.preventDefault();
          window.scrollTo({ top: 0, behavior: "smooth" });
        }}>
          <MeloLockup />
        </a>

        <div className={`nav__links ${menuOpen ? "nav__links--open" : ""}`}>
          {links.map((l) => (
            <a
              key={l.href}
              href={l.href}
              className={l.href === "#demo" && demoActive ? "nav__link--hidden" : undefined}
              onClick={(e) => smoothScroll(e, l.href)}
            >
              {l.label}
            </a>
          ))}

          {/* <div className="nav__anim-selectors">
            <select
              className="nav__anim-select"
              value={enterStyle}
              onChange={(e) => setEnterStyle(e.target.value as typeof enterStyle)}
              aria-label="Enter animation style"
            >
              {animationStyles.map((s) => (
                <option key={s.id} value={s.id}>Enter: {s.label}</option>
              ))}
            </select>
            <select
              className="nav__anim-select"
              value={leaveStyle}
              onChange={(e) => setLeaveStyle(e.target.value as typeof leaveStyle)}
              aria-label="Leave animation style"
            >
              {animationStyles.map((s) => (
                <option key={s.id} value={s.id}>Leave: {s.label}</option>
              ))}
            </select>
          </div> */}

          <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" className="nav__github">
            <GitHubIcon />
          </a>
          <a href={DISCORD_URL} target="_blank" rel="noopener noreferrer" className="nav__github" aria-label="Discord">
            <DiscordIcon />
          </a>
        </div>

        <button className="nav__hamburger" onClick={() => setMenuOpen(!menuOpen)} aria-label="Toggle menu">
          <span /><span /><span />
        </button>
      </div>
    </nav>
  );
}
