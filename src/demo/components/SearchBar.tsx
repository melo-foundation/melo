import { useState } from "react";
import { Icon } from "../icons";
import CustomSelect from "./CustomSelect";

export default function SearchBar({
  onSearch,
  disabled,
  placeholder,
  onLiveChange,
}: {
  onSearch: (query: string, filters?: SearchFilters) => void;
  disabled: boolean;
  placeholder?: string;
  onLiveChange?: (query: string) => void;
}) {
  const [query, setQuery] = useState("");
  const [showFilters, setShowFilters] = useState(false);
  const [sort, setSort] = useState<NonNullable<SearchFilters["sort"]>>("relevance");
  const [type, setType] = useState<NonNullable<SearchFilters["type"]>>("any");
  const [uploadDate, setUploadDate] = useState<NonNullable<SearchFilters["uploadDate"]>>("any");
  const [duration, setDuration] = useState<NonNullable<SearchFilters["duration"]>>("any");

  const buildFilters = (): SearchFilters | undefined => {
    const f: SearchFilters = {};
    if (sort !== "relevance") f.sort = sort;
    if (type !== "any") f.type = type;
    if (uploadDate !== "any") f.uploadDate = uploadDate;
    if (duration !== "any") f.duration = duration;
    return Object.keys(f).length > 0 ? f : undefined;
  };

  const hasFilters = sort !== "relevance" || type !== "any" || uploadDate !== "any" || duration !== "any";

  const submit = () => {
    const q = query.trim();
    if (q) onSearch(q, buildFilters());
  };

  const clearFilters = () => {
    setSort("relevance");
    setType("any");
    setUploadDate("any");
    setDuration("any");
  };

  return (
    <div className="search-bar-wrap">
      <div className="search-bar">
        <div className="search-input-wrap">
          <input
            type="text"
            placeholder={placeholder || "Search YouTube..."}
            value={query}
            onChange={(e) => { setQuery(e.target.value); onLiveChange?.(e.target.value); }}
            onKeyDown={(e) => e.key === "Enter" && submit()}
            disabled={disabled}
          />
          <button
            className="search-input-btn"
            onClick={submit}
            disabled={disabled || !query.trim()}
            title="Search"
          >
            <Icon name="search" size={16} />
          </button>
        </div>
        <button
          className={`search-filter-toggle${showFilters ? " active" : ""}${hasFilters ? " has-filters" : ""}`}
          onClick={() => setShowFilters((p) => !p)}
          title="Search filters"
        >
          <Icon name="filter" size={14} />
        </button>
      </div>

      {showFilters && (
        <div className="search-filters">
          <div className="search-filter-group">
            <label>Sort</label>
            <CustomSelect
              className="search-filter-select"
              value={sort}
              onChange={(v) => setSort(v as typeof sort)}
              options={[
                { value: "relevance", label: "Relevance" },
                { value: "date", label: "Upload date" },
                { value: "views", label: "View count" },
                { value: "rating", label: "Rating" },
              ]}
            />
          </div>

          <div className="search-filter-group">
            <label>Type</label>
            <CustomSelect
              className="search-filter-select"
              value={type}
              onChange={(v) => setType(v as typeof type)}
              options={[
                { value: "any", label: "Any" },
                { value: "video", label: "Video" },
                { value: "playlist", label: "Playlist" },
                { value: "channel", label: "Channel" },
                { value: "movie", label: "Movie" },
              ]}
            />
          </div>

          <div className="search-filter-group">
            <label>Upload date</label>
            <CustomSelect
              className="search-filter-select"
              value={uploadDate}
              onChange={(v) => setUploadDate(v as typeof uploadDate)}
              options={[
                { value: "any", label: "Any time" },
                { value: "hour", label: "Last hour" },
                { value: "today", label: "Today" },
                { value: "week", label: "This week" },
                { value: "month", label: "This month" },
                { value: "year", label: "This year" },
              ]}
            />
          </div>

          <div className="search-filter-group">
            <label>Duration</label>
            <CustomSelect
              className="search-filter-select"
              value={duration}
              onChange={(v) => setDuration(v as typeof duration)}
              options={[
                { value: "any", label: "Any" },
                { value: "short", label: "Under 4 min" },
                { value: "medium", label: "4-20 min" },
                { value: "long", label: "Over 20 min" },
              ]}
            />
          </div>

          {hasFilters && (
            <button className="search-filter-clear" onClick={clearFilters}>
              Clear
            </button>
          )}
        </div>
      )}
    </div>
  );
}
