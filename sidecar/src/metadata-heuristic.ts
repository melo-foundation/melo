export interface TrackMetadata {
  artist?: string;
  cleanTitle?: string;
  album?: string;
  albumArt?: string;
  albumArtFile?: string;
  customArtFile?: string;
  year?: number;
  genre?: string;
  artSource?: "album" | "custom" | "thumbnail" | "default";
  source?: "manual" | "heuristic" | "lastfm" | "musicbrainz" | "deezer";
}

// --- Heuristic parsing ---

/** Remove bracket tags: 【...】, [MV], [Official Video], (cover), {sub esp}, etc. */
export function stripTags(title: string): string {
  return title
    // Full-width brackets: 【...】
    .replace(/[\u3010][^\u3011]*[\u3011]/g, "")
    // Square brackets with known decorators
    .replace(/\[(?:MV|PV|Official\s*(?:Video|Music\s*Video|Audio|Lyric\s*Video)|Lyric(?:s)?\s*Video|Audio|HD|HQ|4K|Full|Sub\s*\w+|CC|EN|JP|歌ってみた|うたってみた|COVER|cover)\]/gi, "")
    // Square brackets with series+format: [Touhou MV], [Toho PV], [touhou PV], etc.
    .replace(/\[(?:Touhou|Toho)\s+(?:MV|PV)\]/gi, "")
    // Square brackets containing resolution/format: [1080p], [60fps], [4K]
    .replace(/\[\d+[pkfsFPS]+\]/gi, "")
    // Parentheses with known decorators
    .replace(/\((?:Official\s*(?:Video|Music\s*Video|Audio|Lyric\s*Video)|Lyric(?:s)?\s*Video|Audio|MV|PV|cover|カバー|歌ってみた|うたってみた|Short\s*Ver\.?|Full\s*Ver\.?|Sub\s*\w+|Original|1Chorus)\)/gi, "")
    // Trailing "/ArtistName(descriptor)" pattern: "KONKON Beats/白上フブキ(Original)" → "KONKON Beats"
    .replace(/\/[^/]+\((?:Original|1Chorus|Short|Full|cover|カバー)\)\s*$/gi, "")
    // Trailing "：ArtistName(descriptor)" pattern: "StaRt/Mrs. GREEN APPLE：白上フブキ(1Chorus)" → "StaRt/Mrs. GREEN APPLE"
    .replace(/[\uff1a：][^：\uff1a]+\((?:Original|1Chorus|Short|Full|cover|カバー)\)\s*$/gi, "")
    // Curly braces with sub tags
    .replace(/\{[^}]*(?:sub|lyrics?|eng|esp|jp)\s*[^}]*\}/gi, "")
    // Trailing "（Vo:name,name）" credit pattern
    .replace(/\s*[（(]Vo[:：][^）)]+[）)]/g, "")
    // Clean up leftover whitespace
    .replace(/\s{2,}/g, " ")
    .trim();
}

/** Detect "ArtistName - Topic" channel pattern */
export function parseTopicChannel(channel: string): string | null {
  const m = channel.match(/^(.+?)\s*-\s*Topic$/);
  return m ? m[1].trim() : null;
}

/** Clean channel name: strip "VEVO", "Music", "Official" suffixes, extract VTuber names */
export function cleanChannelAsArtist(channel: string): string {
  // VTuber pattern: "フブキCh。白上フブキ" → "白上フブキ" (take the name after Ch。/Ch.)
  // But for "Nerissa Ravencroft Ch. hololive-EN", take the name BEFORE Ch.
  const vtuberMatch = channel.match(/^(.+?)\s*Ch[.。]\s*(.+)/);
  if (vtuberMatch) {
    const before = vtuberMatch[1].trim();
    const after = vtuberMatch[2].trim();
    // If "after" is a group name (hololive, NIJISANJI, etc.), use "before"
    if (/hololive|nijisanji|holostars/i.test(after)) return before;
    return after;
  }

  return channel
    .replace(/\s*VEVO$/i, "")
    .replace(/\s*Music$/i, "")
    .replace(/\s*Official$/i, "")
    .trim();
}

/** Split title on " - " or " / " to extract artist + song title */
export function splitTitle(title: string): { artist: string; songTitle: string } | null {
  // Try dash split first (most common): "Artist - Song Title" or "Artist – Song Title" (em dash)
  const dashMatch = title.match(/^(.+?)\s+[-–—]\s+(.+)/);
  if (dashMatch && dashMatch[1].length > 0 && dashMatch[2].length > 0) {
    return {
      artist: dashMatch[1].trim(),
      songTitle: dashMatch[2].trim(),
    };
  }
  // Try full-width slash: "Artist／Song Title"
  const fwSlash = title.indexOf("\uFF0F");
  if (fwSlash > 0 && fwSlash < title.length - 1) {
    return {
      artist: title.slice(0, fwSlash).trim(),
      songTitle: title.slice(fwSlash + 1).trim(),
    };
  }
  // Try " / " (with spaces, to avoid splitting "feat. X / Y")
  const slashIdx = title.indexOf(" / ");
  if (slashIdx > 0 && slashIdx < title.length - 3) {
    // Only split if the left side looks like an artist (no "feat." in left part)
    const left = title.slice(0, slashIdx).trim();
    if (!/feat\.|ft\./i.test(left)) {
      return {
        artist: left,
        songTitle: title.slice(slashIdx + 3).trim(),
      };
    }
  }
  // Try " | " pipe separator: "Title | Artist feat. X"
  const pipeIdx = title.indexOf(" | ");
  if (pipeIdx > 0 && pipeIdx < title.length - 3) {
    return {
      artist: title.slice(0, pipeIdx).trim(),
      songTitle: title.slice(pipeIdx + 3).trim(),
    };
  }
  return null;
}

/** Extract a potential artist name from bracket tags in the title.
 *  Matches patterns like 【IOSYS】, 【東方 IOSYS】, [beatMARIO], [IOSYS] etc. */
function extractBracketArtist(title: string): string | null {
  // Full-width bracket tags: 【IOSYS】, 【東方 IOSYS】, 【IOSYS（まろん&D.watt）】
  const fwMatches = title.match(/[\u3010]([^\u3011]+)[\u3011]/g) || [];
  for (const m of fwMatches) {
    const inner = m.slice(1, -1).trim();
    // Skip format descriptors: 東方MV, Touhou PV, 東方ヴォーカルPV, 公式, COVER, etc.
    if (/^(?:(?:Toho|Touhou|東方)\s*(?:MV|PV|Vocal|ボーカル|ヴォーカル))/i.test(inner)) continue;
    if (/^(?:公式|COVER|カバー|オリジナル楽曲|FullMV|遅刻組|影絵)$/i.test(inner)) continue;
    // Skip standalone series names (not artist names)
    if (/^(?:東方|Touhou|Toho)$/i.test(inner)) continue;
    // Skip event names: 第N回東方ニコ童祭, etc.
    if (/^第\d+回/.test(inner)) continue;
    // Skip game/product names with multi-word descriptors: "maimai でらっくす", "チュウニズム", etc.
    if (/^(?:maimai|chunithm|チュウニズム|SDVX|beatmania|IIDX|jubeat|ongeki|オンゲキ|プロセカ)\b/i.test(inner)) continue;
    // Extract artist from "東方 IOSYS" or "Touhou IOSYS PV" pattern
    const embedded = inner.match(/^(?:(?:東方|Touhou|Toho)\s+)?(\S+)/i);
    if (embedded) {
      const candidate = embedded[1].replace(/[（(][^）)]*[）)]$/, "").trim();
      // Skip series names, format descriptors
      if (/^(?:東方|Touhou|Toho|MV|PV|HD|4K|第\d)$/i.test(candidate)) continue;
      if (candidate.length > 1) return candidate;
    }
  }
  // Square bracket tags: [IOSYS], [beatMARIO]
  const sqMatches = title.match(/\[([^\]]+)\]/g) || [];
  for (const m of sqMatches) {
    const inner = m.slice(1, -1).trim();
    if (/^(?:MV|PV|Official|Lyric|Audio|HD|HQ|4K|Full|Sub|CC|EN|JP|Toho|Touhou|\d+[pkfsFPS])/i.test(inner)) continue;
    if (/^(?:歌ってみた|うたってみた|COVER|cover)$/i.test(inner)) continue;
    if (inner.length > 1 && inner.length < 40) return inner;
  }
  return null;
}

/** Detect if a string is a Vocaloid/UTAU/synth character name (not a real artist) */
function isVocaloidCharacter(name: string): boolean {
  const stripped = name.replace(/\s*(SV|CV|V4X?|NT)\s*$/i, "").trim();
  return /^(?:初音ミク|鏡音リン|鏡音レン|巡音ルカ|MEIKO|KAITO|GUMI|IA|flower|重音テト|亞北ネル|弱音ハク|音街ウナ|可不|星界|小春六花|ずんだもん|東北きりたん|結月ゆかり|紲星あかり|琴葉茜|琴葉葵|Hatsune Miku|Kagamine Rin|Kagamine Len|Megurine Luka|Kasane Teto|Akita Neru|Yowane Haku|Otomachi Una)$/i.test(stripped);
}

/** Main heuristic: suggest metadata from raw YouTube title + channel */
export function suggestMetadata(title: string, channel: string): TrackMetadata {
  const bracketHint = extractBracketArtist(title);
  const cleaned = stripTags(title);
  const topicArtist = parseTopicChannel(channel);

  const channelArtist = cleanChannelAsArtist(channel);

  // Case 1: Topic channel — title is usually clean, channel has artist
  if (topicArtist) {
    // Title might still contain "Artist - Song" in some cases
    const split = splitTitle(cleaned);
    if (split) {
      // If the right side matches/starts with the channel/artist, format is "Song / Artist"
      if (split.songTitle === topicArtist || split.songTitle === channel
        || split.songTitle.startsWith(topicArtist) || split.songTitle.startsWith(channel)) {
        return { artist: topicArtist, cleanTitle: split.artist, source: "heuristic" };
      }
      return {
        artist: split.artist,
        cleanTitle: split.songTitle,
        source: "heuristic",
      };
    }
    return {
      artist: topicArtist,
      cleanTitle: cleaned,
      source: "heuristic",
    };
  }

  // Case 2: Title contains "Artist - Song" or "Song / Artist"
  const split = splitTitle(cleaned);
  if (split) {
    // Detect "Song - Artist Lyrics" pattern (lyrics videos): swap and strip "Lyrics"
    if (/\s+Lyrics?\s*$/i.test(split.songTitle)) {
      const strippedArtist = split.songTitle.replace(/\s+Lyrics?\s*$/i, "").trim();
      return { artist: strippedArtist, cleanTitle: split.artist, source: "heuristic" };
    }
    // Detect "Song - off vocal version" / "Song - instrumental" — the right side is a marker, not a title
    if (/^(?:off\s*vocal(?:\s*ver(?:sion)?\.?)?|instrumental(?:\s*ver(?:sion)?\.?)?|karaoke(?:\s*ver(?:sion)?\.?)?|カラオケ|オフボーカル|inst\.?)\s*$/i.test(split.songTitle)) {
      return { artist: channelArtist, cleanTitle: split.artist, source: "heuristic" };
    }
    // If the right side matches/starts with the channel name, format is "Song / Artist"
    if (split.songTitle === channel || split.songTitle === channelArtist
      || (channelArtist.length > 2 && /^[\s,（(]/.test(split.songTitle.slice(channelArtist.length))
          && split.songTitle.startsWith(channelArtist))) {
      return { artist: channelArtist, cleanTitle: split.artist, source: "heuristic" };
    }
    // If the left side is noise (MV/PV prefix), skip it and use right side
    const noiseMatch = split.artist.match(/^(?:(?:Toho|Touhou|東方)\s*(?:MV|PV)|MV|PV)\s*$/i)
      || split.artist.match(/^(IOSYS)\s*McDonald['\u2019]?s?\s*Ad\s*$/i)
      || split.artist.match(/^Hakurei\s+(?:Reitai|Flash)\s+\w+$/i);
    if (noiseMatch) {
      // Extract embedded artist name from noise if possible (e.g., "IOSYS McDonald's Ad" → "IOSYS")
      const embeddedArtist = noiseMatch[1] || null;
      // Re-split the right side if possible
      const resplit = splitTitle(split.songTitle);
      if (resplit) {
        if (resplit.songTitle === channel || resplit.songTitle === channelArtist) {
          return { artist: channelArtist, cleanTitle: resplit.artist, source: "heuristic" };
        }
        return { artist: resplit.artist, cleanTitle: resplit.songTitle, source: "heuristic" };
      }
      // Try to extract artist name from right side: "IOSYS Touhou Animation" → "IOSYS"
      const rightWords = split.songTitle.split(/\s+/);
      const firstWord = rightWords[0];
      if (!embeddedArtist && rightWords.length > 1 && firstWord.length > 2
          && /^[A-Za-z]/.test(firstWord) && !/^(?:The|A|An|My|In|On|At|To|Of|For|And|But|Or|So|No|Up|It|He|She|We|Do|If)$/i.test(firstWord)) {
        // First word of right side might be the artist (e.g., "IOSYS Touhou Animation")
        const restTitle = rightWords.slice(1).join(" ");
        return { artist: firstWord, cleanTitle: restTitle, source: "heuristic" };
      }
      const artist = embeddedArtist || channelArtist;
      return { artist, cleanTitle: split.songTitle, source: "heuristic" };
    }
    // If the right side is a known Vocaloid/UTAU character, format is "Song / Character"
    // Use channel as artist (the actual producer)
    if (isVocaloidCharacter(split.songTitle)) {
      return { artist: channelArtist, cleanTitle: split.artist, source: "heuristic" };
    }
    return {
      artist: split.artist,
      cleanTitle: split.songTitle,
      source: "heuristic",
    };
  }

  // Case 2.5: Extract artist from [BracketTag] in title (e.g., "[IOSYS] Song Title")
  const bracketArtist = cleaned.match(/^\[([^\]]+)\]\s*(.+)/);
  if (bracketArtist) {
    const tag = bracketArtist[1].trim();
    const rest = bracketArtist[2].trim();
    // Only use if the tag doesn't look like a format descriptor or series prefix
    if (!/^(?:MV|PV|HD|HQ|4K|Full|Official|Lyric|Sub|CC|EN|JP|Touhou|Toho)/i.test(tag)) {
      return { artist: tag, cleanTitle: rest, source: "heuristic" };
    }
  }

  // Case 3: No split possible — use bracket hint, cleaned channel, or title as-is
  if (cleaned !== title || channelArtist !== channel || bracketHint) {
    // Prefer bracket-extracted artist over channel name for reupload channels
    const artist = bracketHint || channelArtist;
    return {
      artist,
      cleanTitle: cleaned,
      source: "heuristic",
    };
  }

  // Nothing to suggest
  return { source: "heuristic" };
}

/**
 * Clean artist/title for API queries.
 * Strips "feat./ft." clauses, bracket suffixes, and other noise
 * that would prevent API matches.
 */
export function cleanForQuery(artist: string, title: string): { artist: string; title: string } {
  let a = artist;
  let t = title;

  // --- Artist cleaning ---
  // Strip "@" prefix (YouTube handles)
  a = a.replace(/^@/, "");
  // Strip "(CV: name)" voice actor credits
  a = a.replace(/\s*\(CV[:：]\s*[^)]+\)/gi, "").trim();
  // Strip "feat./ft. X" from artist
  a = a.replace(/\s*(?:feat\.?|ft\.?)\s*.+$/i, "").trim();
  // Strip everything after "/" in artist (use first artist only): "beatMARIO / COOL&CREATE" → "beatMARIO"
  a = a.replace(/\s*\/\s*.+$/, "").trim();
  // Strip "・altName" from Japanese artist names: "はろける・HALLO CEL" → "はろける"
  a = a.replace(/[・·]\s*.+$/, "").trim();

  // --- Title cleaning ---
  // Strip ALL square bracket content: [Touhou MV], [IOSYS], [beatMARIO], [1080p], etc.
  t = t.replace(/\s*\[[^\]]*\]\s*/g, " ").trim();
  // Strip parenthetical feat/ft FIRST (before end-of-string strip): (feat. X), (ft. Y)
  t = t.replace(/\s*\((?:feat\.?|ft\.?)\s+[^)]+\)/gi, "").trim();
  // Strip "(CV: name)" voice actor credits from title
  t = t.replace(/\s*\(CV[:：]\s*[^)]+\)/gi, "").trim();
  // Strip parenthesized format/version/credit tags (comprehensive)
  t = t.replace(/\s*\((?:Lyrics?|Visuali[sz]er?|Official\s+[^)]*(?:Video|Audio)|Official\s*(?:Music\s*)?(?:Video|Audio)|Music\s*Video|Performance\s*Video|Full\s*(?:Ver\.?|Version)?|Short\s*(?:Ver\.?|Version)?|Studio\s*(?:Ver(?:sion)?\.?)?|Live\s+(?:at|in|from|Version)\b[^)]*|Remaster(?:ed)?[^)]*|Acoustic(?:\s*Ver(?:sion)?\.?)?|Unplugged|Demo|Radio(?:\s*(?:Edit|Ver(?:sion)?))?|Extended(?:\s*(?:Ver(?:sion)?|Mix))?|Album\s*Track|HD|HQ|High\s*Quality|AC3[^)]*|Stereo|Uncensored!?|Cover\s+by\s+[^)]*|Prod\.?\s+by\s+[^)]*|Theme\s+for\s+[^)]*|From\s+[^)]*|WSHH[^)]*|cover|カバー)\)/gi, "").trim();
  // Strip trailing (YEAR): (1988), (2020), etc.
  t = t.replace(/\s*\(\d{4}\)/g, "").trim();
  // Strip trailing (text, YEAR): "(Atlantic Records,1991)", "(Sinfonia..., 1985)"
  t = t.replace(/\s*\([^)]*,\s*\d{4}\)\s*$/g, "").trim();
  // Strip parenthesized artist names that match known patterns: (Nerissa Ravencroft), (しぐれうい)
  // Only strip if they look like a name attribution, not song info
  t = t.replace(/\s*\((?:Nerissa\s+Ravencroft|[^)]{1,20}(?:9さい|さん))\)/gi, "").trim();
  // Strip "(Full / 4k)" and similar resolution/format tags
  t = t.replace(/\s*\(Full\s*\/\s*\d+[kK]\)/g, "").trim();
  // Strip emoji (food, objects, etc. — NOT miscellaneous symbols like ☆♪) — replace with space
  t = t.replace(/[\u{1F300}-\u{1F9FF}]+/gu, " ").trim();
  // Strip full-width alphanumeric → ASCII equivalents for matching
  t = t.replace(/[\uFF10-\uFF19\uFF21-\uFF3A\uFF41-\uFF5A]+/g, (m) =>
    String.fromCharCode(...[...m].map((c) => c.charCodeAt(0) - 0xFEE0)),
  );
  // Strip Japanese bracket quotes 「」and 『』
  t = t.replace(/[\u300C\u300E]([^\u300D\u300F]+)[\u300D\u300F]/g, "$1").trim();
  // Strip "PV" tag from title (common in Japanese music videos)
  t = t.replace(/\s+PV\s*$/i, "").trim();
  // Strip Vocaloid synthesizer suffixes (SV, CV) from artist-like strings at end
  t = t.replace(/\s*(?:SV|CV)\s*$/i, "").trim();
  // Strip trailing "English & Romaji subs" or similar subtitle markers
  t = t.replace(/\s+(?:English|Romaji|EN|JP)\s*(?:&\s*(?:English|Romaji|EN|JP)\s*)?(?:subs?|lyrics?)\s*$/gi, "").trim();
  // NOW strip trailing "feat./ft. X" — use word boundary to avoid matching inside words like "Ravencroft"
  t = t.replace(/\s+\b(?:feat\.?|ft\.)\s*.+$/i, "").trim();
  // Strip trailing "Lyrics" word
  t = t.replace(/\s+Lyrics?\s*$/i, "").trim();
  // Strip trailing quoted strings: "English subs + Romaji Lyrics"
  t = t.replace(/\s*"[^"]*(?:subs?|lyrics?|sub\s*\w+)[^"]*"\s*$/gi, "").trim();
  // Strip "(歌唱:name)" vocal credits and trailing "（原曲：...）" source credits
  t = t.replace(/[/／]\s*歌唱[:：][^)）]*/g, "").trim();
  t = t.replace(/[（(]原曲[:：][^）)]*[）)]/g, "").trim();
  // Strip ≪...≫ guillemet markers (Japanese double angle brackets)
  t = t.replace(/\s*[\u226A\u300A].*?[\u226B\u300B]/g, "").trim();
  // Strip stray closing parentheses/brackets
  t = t.replace(/^[）)]+\s*/, "").replace(/\s*[）)]+$/, "").trim();
  // Strip smart/curly double quotes (keep content): "The Wizard" → The Wizard
  t = t.replace(/[\u201C\u201D\u201E""]/g, "").trim();
  // Strip trailing " - Official - YEAR" pattern
  t = t.replace(/\s*-\s*Official\s*-\s*\d{4}\s*$/gi, "").trim();
  // Strip trailing quality/format markers: " - HQ", " - HD", " - HIGH DEFINITION", " - Watch In High Quality"
  t = t.replace(/\s*-\s*(?:HQ|HD|HIGH\s+DEFINITION|Watch\s+In\s+High\s+Quality)\s*$/gi, "").trim();
  // Strip trailing resolution/quality: "HQ 480p", "HD 1080p"
  t = t.replace(/\s+(?:HQ|HD)\s*\d*[pkK]?\s*$/gi, "").trim();
  // Strip trailing arrangement/cover descriptors: "Jazz Cover", "Piano Cover", etc.
  t = t.replace(/\s+(?:(?:Jazz|Piano|Guitar|Violin|Acoustic|Orchestral?|Big\s+Band|Latin\s+Jazz(?:\s+Fusion)?)\s+)?(?:Cover|Arrangement)\s*$/gi, "").trim();
  // Strip instrumental/karaoke/off-vocal markers for cleaner API queries
  t = t.replace(/\s*[-–—]\s*(?:off\s*vocal(?:\s*ver(?:sion)?\.?)?|instrumental(?:\s*ver(?:sion)?\.?)?|karaoke|カラオケ|オフボーカル|inst\.?)\s*$/i, "").trim();
  t = t.replace(/\s*[（(](?:off\s*vocal(?:\s*ver(?:sion)?\.?)?|instrumental(?:\s*ver(?:sion)?\.?)?|karaoke|カラオケ|オフボーカル|inst\.?)[）)]/gi, "").trim();
  // Collapse whitespace
  t = t.replace(/\s{2,}/g, " ").trim();

  return { artist: a || artist, title: t || title };
}
