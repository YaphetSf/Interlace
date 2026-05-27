/**
 * Interlace Console - API Type Definitions
 * 
 * These interfaces map directly to the backend FastAPI endpoints.
 * They serve as the single source of truth for both the React/Vite web console
 * and the native iOS/Swift application models.
 */

/**
 * Represent a single download task managed by aria2.
 */
export interface DownloadItem {
  gid: string;
  name: string;
  status: 'active' | 'waiting' | 'paused' | 'complete' | 'error' | 'removed';
  total: number;
  completed: number;
  progress: number; // calculated 0 to 100
  speed: number;    // bytes per second
  is_torrent: boolean;
  error: string | null;
}

/**
 * System disk space information.
 */
export interface DiskInfo {
  total: number;
  used: number;
  free: number;
  percent: number; // percent of used disk space
}

/**
 * A playable video file found in the library scan.
 */
export interface VideoItem {
  name: string;
  path: string;
  size?: number;
  rel: string;
  type?: 'file' | 'directory';
}

/**
 * Return format for GET /api/library.
 */
export interface LibraryData {
  items: VideoItem[];
  disk: DiskInfo | null;
}

/**
 * An audio stream inside a video file, retrieved from Kodi.
 */
export interface AudioStream {
  index: number;
  language: string | null;
  name: string | null;
  codec: string | null;
}

/**
 * A video stream inside a video file, retrieved from Kodi.
 */
export interface VideoStream {
  index: number;
  name: string | null;
  width: number | null;
  height: number | null;
  codec: string | null;
}

/**
 * An external or embedded subtitle track, retrieved from Kodi.
 */
export interface SubtitleStream {
  index: number;
  language: string | null;
  name: string | null;
}

/**
 * The current state of Kodi playback.
 * Property fields are optional when `active` is false.
 */
export interface PlaybackState {
  active: boolean;
  playerid?: number;
  title?: string;
  file?: string;
  percentage?: number;
  time?: number;
  totaltime?: number;
  speed?: number; // 0 is paused, 1 is active play
  audiostreams?: AudioStream[];
  currentaudiostream?: { index: number } | null;
  videostreams?: VideoStream[];
  currentvideostream?: { index: number } | null;
  subtitles?: SubtitleStream[];
  currentsubtitle?: { index: number } | null;
  subtitleenabled?: boolean;
  volume: number; // 0 to 100
  muted: boolean;
}

export interface UploadTask {
  id: string;
  name: string;
  size: number;
  progress: number;
  status: 'uploading' | 'done' | 'error';
  error: string | null;
}
