export interface SearchResult {
  id: string;
  title: string;
  channel: string;
  thumbnail: string;
  duration: number;
}

export interface StreamResult {
  audioUrl: string;
  duration: number;
  title: string;
  channel: string;
  thumbnail: string;
  relatedStreams: SearchResult[];
}

export type ApiResponse<T> = {
  ok: true;
  data: T;
} | {
  ok: false;
  error: string;
}
