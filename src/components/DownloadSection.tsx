import { ScrollReveal } from "./ScrollReveal";

const RELEASES_URL = "https://github.com/melo-foundation/melo/releases";
const GITHUB_URL = "https://github.com/melo-foundation/melo";

const platforms = [
  {
    name: "Linux",
    icon: "linux",
    format: "AppImage",
    desc: "Portable, no installation needed.",
    href: `${RELEASES_URL}/latest/download/melo-x86_64.AppImage`,
  },
  {
    name: "Windows",
    icon: "windows",
    format: "Installer + Portable",
    desc: "NSIS installer or standalone portable executable.",
    disabled: true,
  },
  {
    name: "macOS",
    icon: "macos",
    format: "DMG",
    desc: "Universal binary for Apple Silicon and Intel Macs.",
    disabled: true,
  },
];

function PlatformIcon({ icon }: { icon: string }) {
  if (icon === "linux") {
    return (
      <svg viewBox="0 0 24 24" fill="currentColor" className="platform-icon">
        <path d="M12.504 0c-.155 0-.315.008-.48.021-4.226.333-3.105 4.807-3.17 6.298-.076 1.092-.3 1.953-1.05 3.02-.885 1.051-2.127 2.75-2.716 4.521-.278.832-.41 1.684-.287 2.489a.424.424 0 00-.11.135c-.26.268-.45.6-.663.839-.199.199-.485.267-.797.4-.313.136-.658.269-.864.68-.09.189-.136.394-.132.602 0 .199.027.4.055.536.058.399.116.728.04.97-.249.68-.28 1.145-.106 1.484.174.334.535.47.94.601.81.2 1.91.135 2.774.6.926.466 1.866.67 2.616.47.526-.116.97-.464 1.208-.946.587-.003 1.23-.269 2.26-.334.699-.058 1.574.267 2.577.2.025.134.063.198.114.333l.003.003c.391.778 1.113 1.368 1.884 1.43.199.015.273.16.373.27.135.15.263.468.543.444.276-.022.376-.279.49-.451.228-.348.267-.596.29-.135.005.116.082.26.226.337.14.06.275.03.4-.069.228-.178.32-.425.3-.674-.03-.4-.142-.619-.063-.674.095-.06.135-.133.24-.39.126-.297.037-.614-.111-.907-.096-.244-.256-.397-.34-.607-.054-.133-.07-.2-.063-.267.01-.08.004-.133-.026-.198a.424.424 0 00-.061-.11c.24-.166.437-.395.594-.665.399-.735.535-1.693.18-2.593-.334-.845-.918-1.46-1.394-2.06-.469-.587-.821-1.15-.95-1.728-.12-.534-.186-1.287-.12-2.158.055-.853.184-1.807.141-2.774-.03-.846-.15-1.712-.517-2.44C15.23 1.262 13.956 0 12.504 0z" />
      </svg>
    );
  }
  if (icon === "windows") {
    return (
      <svg viewBox="0 0 24 24" fill="currentColor" className="platform-icon">
        <path d="M0 3.449L9.75 2.1v9.451H0m10.949-9.602L24 0v11.4H10.949M0 12.6h9.75v9.451L0 20.699M10.949 12.6H24V24l-12.9-1.801" />
      </svg>
    );
  }
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" className="platform-icon">
      <path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z" />
    </svg>
  );
}

export function DownloadSection() {
  return (
    <section id="download" className="section">
      <div className="container">
        <ScrollReveal>
          <h2 className="section-title">Download melo</h2>
          <p className="section-subtitle">Free and open source.</p>
        </ScrollReveal>

        <div className="download__grid">
          {platforms.map((p) => (
            <ScrollReveal key={p.name}>
              {p.disabled ? (
                <div className="download__card download__card--disabled glass" aria-disabled="true">
                  <PlatformIcon icon={p.icon} />
                  <h3>{p.name}</h3>
                  <span className="download__format">{p.format}</span>
                  <p>{p.desc}</p>
                </div>
              ) : (
                <a href={p.href} className="download__card glass" download>
                  <PlatformIcon icon={p.icon} />
                  <h3>{p.name}</h3>
                  <span className="download__format">{p.format}</span>
                  <p>{p.desc}</p>
                </a>
              )}
            </ScrollReveal>
          ))}
        </div>

        <ScrollReveal>
        <div className="download__source">
          <p>
            <a href={`${RELEASES_URL}/latest`} target="_blank" rel="noopener noreferrer">Other formats</a> (lite AppImage, deb, rpm, Arch) or{" "}
            <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer">build from source</a>
          </p>
          <code className="download__snippet">
            git clone {GITHUB_URL}.git && cd melo && cmake -B build && cmake --build build
          </code>
        </div>
        </ScrollReveal>
      </div>
    </section>
  );
}
