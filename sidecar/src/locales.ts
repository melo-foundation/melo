// The locales YouTube accepts as `hl`, and how to show them. Static: only an
// authenticated account menu serves the list. The settings UI reads this copy
// over RPC, so the picker cannot offer a code the validator rejects.

export interface LocaleEntry { code: string; english: string; native: string }

export const LOCALES: LocaleEntry[] = [
  { code: "af",      english: "Afrikaans",               native: "Afrikaans" },
  { code: "az",      english: "Azerbaijani",             native: "Azərbaycan" },
  { code: "id",      english: "Indonesian",              native: "Bahasa Indonesia" },
  { code: "ms",      english: "Malay",                   native: "Bahasa Melayu" },
  { code: "bs",      english: "Bosnian",                 native: "Bosanski" },
  { code: "ca",      english: "Catalan",                 native: "Català" },
  { code: "cs",      english: "Czech",                   native: "Čeština" },
  { code: "da",      english: "Danish",                  native: "Dansk" },
  { code: "de",      english: "German",                  native: "Deutsch" },
  { code: "et",      english: "Estonian",                native: "Eesti" },
  { code: "en-GB",   english: "English (UK)",            native: "English (UK)" },
  { code: "en",      english: "English (US)",            native: "English (US)" },
  { code: "es",      english: "Spanish (Spain)",         native: "Español (España)" },
  { code: "es-419",  english: "Spanish (Latin America)", native: "Español (Latinoamérica)" },
  { code: "es-US",   english: "Spanish (US)",            native: "Español (Estados Unidos)" },
  { code: "eu",      english: "Basque",                  native: "Euskara" },
  { code: "fil",     english: "Filipino",                native: "Filipino" },
  { code: "fr",      english: "French",                  native: "Français" },
  { code: "fr-CA",   english: "French (Canada)",         native: "Français (Canada)" },
  { code: "gl",      english: "Galician",                native: "Galego" },
  { code: "hr",      english: "Croatian",                native: "Hrvatski" },
  { code: "zu",      english: "Zulu",                    native: "IsiZulu" },
  { code: "is",      english: "Icelandic",               native: "Íslenska" },
  { code: "it",      english: "Italian",                 native: "Italiano" },
  { code: "sw",      english: "Swahili",                 native: "Kiswahili" },
  { code: "lv",      english: "Latvian",                 native: "Latviešu" },
  { code: "lt",      english: "Lithuanian",              native: "Lietuvių" },
  { code: "hu",      english: "Hungarian",               native: "Magyar" },
  { code: "nl",      english: "Dutch",                   native: "Nederlands" },
  { code: "no",      english: "Norwegian",               native: "Norsk" },
  { code: "uz",      english: "Uzbek",                   native: "O‘zbek" },
  { code: "pl",      english: "Polish",                  native: "Polski" },
  { code: "pt-PT",   english: "Portuguese (Portugal)",   native: "Português (Portugal)" },
  { code: "pt",      english: "Portuguese (Brazil)",     native: "Português (Brasil)" },
  { code: "ro",      english: "Romanian",                native: "Română" },
  { code: "sq",      english: "Albanian",                native: "Shqip" },
  { code: "sk",      english: "Slovak",                  native: "Slovenčina" },
  { code: "sl",      english: "Slovenian",               native: "Slovenščina" },
  { code: "sr-Latn", english: "Serbian (Latin)",         native: "Srpski (latinica)" },
  { code: "fi",      english: "Finnish",                 native: "Suomi" },
  { code: "sv",      english: "Swedish",                 native: "Svenska" },
  { code: "vi",      english: "Vietnamese",              native: "Tiếng Việt" },
  { code: "tr",      english: "Turkish",                 native: "Türkçe" },
  { code: "be",      english: "Belarusian",              native: "Беларуская" },
  { code: "bg",      english: "Bulgarian",               native: "Български" },
  { code: "ky",      english: "Kyrgyz",                  native: "Кыргызча" },
  { code: "kk",      english: "Kazakh",                  native: "Қазақ Тілі" },
  { code: "mk",      english: "Macedonian",              native: "Македонски" },
  { code: "mn",      english: "Mongolian",               native: "Монгол" },
  { code: "ru",      english: "Russian",                 native: "Русский" },
  { code: "sr",      english: "Serbian",                 native: "Српски" },
  { code: "uk",      english: "Ukrainian",               native: "Українська" },
  { code: "el",      english: "Greek",                   native: "Ελληνικά" },
  { code: "hy",      english: "Armenian",                native: "Հայերեն" },
  { code: "iw",      english: "Hebrew",                  native: "עברית" },
  { code: "ur",      english: "Urdu",                    native: "اردو" },
  { code: "ar",      english: "Arabic",                  native: "العربية" },
  { code: "fa",      english: "Persian",                 native: "فارسی" },
  { code: "ne",      english: "Nepali",                  native: "नेपाली" },
  { code: "mr",      english: "Marathi",                 native: "मराठी" },
  { code: "hi",      english: "Hindi",                   native: "हिन्दी" },
  { code: "bn",      english: "Bengali",                 native: "বাংলা" },
  { code: "pa",      english: "Punjabi",                 native: "ਪੰਜਾਬੀ" },
  { code: "gu",      english: "Gujarati",                native: "ગુજરાતી" },
  { code: "or",      english: "Oriya",                   native: "ଓଡ଼ିଆ" },
  { code: "ta",      english: "Tamil",                   native: "தமிழ்" },
  { code: "te",      english: "Telugu",                  native: "తెలుగు" },
  { code: "kn",      english: "Kannada",                 native: "ಕನ್ನಡ" },
  { code: "ml",      english: "Malayalam",               native: "മലയാളം" },
  { code: "si",      english: "Sinhala",                 native: "සිංහල" },
  { code: "th",      english: "Thai",                    native: "ภาษาไทย" },
  { code: "lo",      english: "Lao",                     native: "ລາວ" },
  { code: "my",      english: "Burmese",                 native: "ဗမာ" },
  { code: "ka",      english: "Georgian",                native: "ქართული" },
  { code: "am",      english: "Amharic",                 native: "አማርኛ" },
  { code: "km",      english: "Khmer",                   native: "ខ្មែរ" },
  { code: "zh-CN",   english: "Chinese (Simplified)",    native: "中文 (简体)" },
  { code: "zh-TW",   english: "Chinese (Traditional)",   native: "中文 (繁體)" },
  { code: "zh-HK",   english: "Chinese (Hong Kong)",     native: "中文 (香港)" },
  { code: "ja",      english: "Japanese",                native: "日本語" },
  { code: "ko",      english: "Korean",                  native: "한국어" },
];

const SUPPORTED = new Set(LOCALES.map((l) => l.code.toLowerCase()));

/** Will YouTube accept this as hl? Unsupported codes (zxx/und/mul, cy, mi, haw)
 *  return no usable payload, and an unset LANG resolves to "und", which is
 *  common on headless and service launches. */
export function isSupportedLocale(code: string): boolean {
  const c = (code || "").toLowerCase();
  if (SUPPORTED.has(c)) return true;
  return SUPPORTED.has(c.split("-")[0]);   // "ja-JP" -> "ja"
}

/** Nearest supported code, or "" when there is none. */
export function nearestSupported(code: string): string {
  const c = (code || "").toLowerCase();
  for (const l of LOCALES) if (l.code.toLowerCase() === c) return l.code;
  const base = c.split("-")[0];
  for (const l of LOCALES) if (l.code.toLowerCase() === base) return l.code;
  return "";
}

// ---- regions (gl) -------------------------------------------------------
// gl steers recommendations and availability, not titles, and unlike hl it
// tolerates junk (gl=XX and gl="" both return a normal payload), so it needs a
// picker, not a validator. Generated from Intl's ISO 3166 table.
export interface RegionEntry { code: string; name: string }

let regionCache: RegionEntry[] | null = null;

export function REGIONS(): RegionEntry[] {
  if (regionCache) return regionCache;
  const out: RegionEntry[] = [];
  try {
    const dn = new Intl.DisplayNames(["en"], { type: "region" });
    for (let a = 65; a <= 90; a++) {
      for (let b = 65; b <= 90; b++) {
        const code = String.fromCharCode(a, b);
        let name: string | undefined;
        try { name = dn.of(code); } catch { continue; }
        if (name && name !== code) out.push({ code, name });
      }
    }
  } catch { /* no Intl region data — the picker just shows nothing */ }
  out.sort((x, y) => x.name.localeCompare(y.name));
  regionCache = out;
  return out;
}

export function isSupportedRegion(code: string): boolean {
  const c = (code || "").toUpperCase();
  return REGIONS().some((r) => r.code === c);
}
