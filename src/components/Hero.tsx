import { MeloIcon } from "./icons";
import { ScrollReveal } from "./ScrollReveal";

const GITHUB_URL = "https://github.com/melo-foundation/melo";

export function Hero() {
  return (
    <section className="hero">
      <div className="hero__content container">
        <ScrollReveal>
          <div className="hero__icon">
            <MeloIcon />
          </div>
        </ScrollReveal>
        <ScrollReveal>
          <h1 className="hero__title">melo</h1>
        </ScrollReveal>
        <ScrollReveal>
          <p className="hero__tagline">
            A YouTube integrated native desktop music player.
          </p>
        </ScrollReveal>
        <ScrollReveal>
          <div className="hero__actions">
            <a href="#download" className="btn btn-primary" onClick={(e) => {
              e.preventDefault();
              document.querySelector("#download")?.scrollIntoView({ behavior: "smooth", block: "start" });
            }}>Download</a>
            <a href="#demo" className="btn btn-outline" onClick={(e) => {
              e.preventDefault();
              const el = document.querySelector("#demo");
              if (el) {
                const rect = el.getBoundingClientRect();
                const top = rect.top + window.scrollY - (window.innerHeight - rect.height) / 2;
                window.scrollTo({ top: Math.max(0, top), behavior: "smooth" });
              }
            }}>Try Demo</a>
            <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" className="btn btn-outline">
              View on GitHub
            </a>
          </div>
        </ScrollReveal>
      </div>
    </section>
  );
}
