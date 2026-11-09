export default function activate(melo) {
  melo.registerSource({
    id: "sample",
    name: "Sample Source",
    search: async (query) => ({
      tracks: [{ id: "smp:1", source: "sample", title: `hit for ${query}`,
                 channel: "Fixture", duration: 60, thumbnail: "" }],
      continuation: null,
    }),
    resolveStream: async (trackId) => ({ url: new URL(`assets/${trackId}.opus`, import.meta.url).href }),
  });
  melo.player.on("trackChanged", ({ track }) => melo.log("saw trackChanged", track.id));
}
