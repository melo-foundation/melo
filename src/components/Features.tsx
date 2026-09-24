import { ScrollReveal } from "./ScrollReveal";

const features = [
  {
    icon: "play",
    title: "Play Anything",
    desc: "Search and play any song, album, or playlist from YouTube. Queue management, autoplay, and shuffle built in.",
  },
  {
    icon: "download",
    title: "Offline Library",
    desc: "Download tracks for offline playback. Your music, stored locally and always available.",
  },
  {
    icon: "feed",
    title: "Your Feed",
    desc: "Get personalized recommendations, playlists, and mixes tailored to your listening taste and mood.",
  },
  {
    icon: "palette",
    title: "Endless Personalization",
    desc: "Every color, font, background, and effect is customizable. Start from one of 16 built-in themes or make your own.",
  },
  {
    icon: "equalizer",
    title: "Sound Control",
    desc: "10-band EQ with presets, seamless crossfading between tracks, and automatic silence trimming.",
  },
  {
    icon: "lock",
    title: "Open Source",
    desc: "No ads, no extra tracking. Fully open source.",
  },
  {
    icon: "platform",
    title: "Native Qt App",
    desc: "Written in C++ and Qt, with no browser engine inside, so it starts fast and stays light on memory.",
  },
  {
    icon: "metadata",
    title: "Metadata Fetching",
    desc: "Automatically fetches titles, artists, album art, and duration. Your library stays organized without any manual effort.",
  },
];

function FeatureIcon({ icon }: { icon: string }) {
  const paths: Record<string, React.ReactNode> = {
    play: (
      <path d="M8 5.14v14.72a1 1 0 001.5.86l11.5-7.36a1 1 0 000-1.72L9.5 4.28A1 1 0 008 5.14z"
        fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
    ),
    download: (
      <path d="M12 3v12m0 0l-4-4m4 4l4-4M4 17v2a2 2 0 002 2h12a2 2 0 002-2v-2"
        fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    ),
    palette: (
      <>
        <circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" strokeWidth="1.5" />
        <circle cx="9" cy="9" r="1.5" fill="currentColor" />
        <circle cx="15" cy="9" r="1.5" fill="currentColor" />
        <circle cx="9" cy="15" r="1.5" fill="currentColor" />
        <circle cx="15" cy="15" r="1.5" fill="currentColor" />
      </>
    ),
    equalizer: (
      <path d="M4 8v8M8 5v14M12 9v6M16 6v12M20 10v4"
        fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    ),
    feed: (
      <>
        <circle cx="12" cy="8" r="4" fill="none" stroke="currentColor" strokeWidth="1.5" />
        <path d="M4 20c0-4 3.6-7 8-7s8 3 8 7"
          fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
      </>
    ),
    lock: (
      <>
        <rect x="5" y="11" width="14" height="10" rx="2" fill="none" stroke="currentColor" strokeWidth="1.5" />
        <path d="M8 11V7a4 4 0 018 0v4"
          fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
      </>
    ),
    platform: (
      <>
        <rect x="3" y="4" width="18" height="12" rx="2" fill="none" stroke="currentColor" strokeWidth="1.5" />
        <path d="M8 20h8M12 16v4" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
      </>
    ),
    metadata: (
      <>
        <path d="M4 7a2 2 0 012-2h8l6 6v8a2 2 0 01-2 2H6a2 2 0 01-2-2V7z"
          fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
        <path d="M14 5v6h6" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
        <path d="M8 14h8M8 17h5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
      </>
    ),
  };

  return (
    <svg viewBox="0 0 24 24" className="feature-icon">
      {paths[icon]}
    </svg>
  );
}

export function Features() {
  return (
    <section id="features" className="section">
      <div className="container">
        <ScrollReveal>
          <h2 className="section-title">Everything you need</h2>
          <p className="section-subtitle">Fully featured music player with audio only Youtube streaming.</p>
        </ScrollReveal>
        <div className="features__grid">
          {features.map((f) => (
            <ScrollReveal key={f.title}>
              <div className="feature-card glass">
                <FeatureIcon icon={f.icon} />
                <h3>{f.title}</h3>
                <p>{f.desc}</p>
              </div>
            </ScrollReveal>
          ))}
        </div>
      </div>
    </section>
  );
}
