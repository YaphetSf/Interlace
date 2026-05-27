import { DownloadItem, LibraryData, PlaybackState } from './types/api';

const j = <T>(r: Response): Promise<T> => {
  if (!r.ok) return r.text().then((t) => Promise.reject(new Error(t || r.statusText || String(r.status))))
  return r.json() as Promise<T>
}

const post = <T>(url: string, body?: any): Promise<T> =>
  fetch(url, {
    method: 'POST',
    headers: body === undefined ? undefined : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }).then((r) => j<T>(r))

export const api = {
  // downloads
  downloads: (): Promise<DownloadItem[]> => fetch('/api/downloads').then((r) => j<DownloadItem[]>(r)),
  
  addUri: (uri: string): Promise<{ gid: string }> => post<{ gid: string }>('/api/downloads', { uri }),
  
  addTorrent: (file: File): Promise<{ gid: string }> => {
    const fd = new FormData()
    fd.append('file', file)
    return fetch('/api/downloads/torrent', { method: 'POST', body: fd }).then((r) => j<{ gid: string }>(r))
  },
  
  upload: (file: File, path?: string, onProgress?: (percent: number) => void): Promise<{ ok: boolean; filename: string }> => {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest()
      xhr.open('POST', '/api/upload')
      if (xhr.upload && onProgress) {
        xhr.upload.addEventListener('progress', (e) => {
          if (e.lengthComputable) {
            const percent = Math.round((e.loaded / e.total) * 100)
            onProgress(percent)
          }
        })
      }
      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) {
          try {
            resolve(JSON.parse(xhr.responseText))
          } catch (err) {
            resolve({ ok: true, filename: file.name })
          }
        } else {
          reject(new Error(xhr.responseText || `HTTP ${xhr.status}`))
        }
      }
      xhr.onerror = () => reject(new Error('Network error'))
      const fd = new FormData()
      const filename = file.webkitRelativePath || file.name
      fd.append('file', file, filename)
      if (path) {
        fd.append('path', path)
      }
      xhr.send(fd)
    })
  },
  
  uploadSubtitle: (videoPath: string, file: File, onProgress?: (percent: number) => void): Promise<{ ok: boolean }> => {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest()
      xhr.open('POST', '/api/upload/subtitle')
      if (xhr.upload && onProgress) {
        xhr.upload.addEventListener('progress', (e) => {
          if (e.lengthComputable) {
            const percent = Math.round((e.loaded / e.total) * 100)
            onProgress(percent)
          }
        })
      }
      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) {
          try {
            resolve(JSON.parse(xhr.responseText))
          } catch (err) {
            resolve({ ok: true })
          }
        } else {
          reject(new Error(xhr.responseText || `HTTP ${xhr.status}`))
        }
      }
      xhr.onerror = () => reject(new Error('Network error'))
      const fd = new FormData()
      fd.append('video_path', videoPath)
      fd.append('file', file)
      xhr.send(fd)
    })
  },
  
  pause: (gid: string): Promise<any> => post(`/api/downloads/${gid}/pause`),
  resume: (gid: string): Promise<any> => post(`/api/downloads/${gid}/resume`),
  remove: (gid: string): Promise<any> => fetch(`/api/downloads/${gid}`, { method: 'DELETE' }).then((r) => j<any>(r)),

  // library
  library: (path?: string): Promise<LibraryData> => {
    const url = path ? `/api/library?path=${encodeURIComponent(path)}` : '/api/library'
    return fetch(url).then((r) => j<LibraryData>(r))
  },
  removeFile: (path: string): Promise<any> =>
    fetch('/api/library', {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path }),
    }).then((r) => j<any>(r)),

  // playback
  play: (path: string): Promise<any> => post('/api/play', { path }),
  player: (): Promise<PlaybackState> => fetch('/api/player').then((r) => j<PlaybackState>(r)),
  playpause: (): Promise<any> => post('/api/player/playpause'),
  stop: (): Promise<any> => post('/api/player/stop'),
  seek: (percentage: number): Promise<any> => post('/api/player/seek', { percentage }),
  setAudio: (index: number): Promise<any> => post('/api/player/audio', { index }),
  setVideo: (index: number): Promise<any> => post('/api/player/video', { index }),
  setSubtitle: (value: string | number): Promise<any> => post('/api/player/subtitle', { value }),
  setVolume: (level: number): Promise<any> => post('/api/player/volume', { level }),
  setMute: (muted: boolean): Promise<any> => post('/api/player/mute', { muted }),
  subtitleDelay: (direction: 'minus' | 'plus'): Promise<any> => post('/api/player/subtitle-delay', { direction }),
  audioDelay: (direction: 'minus' | 'plus'): Promise<any> => post('/api/player/audio-delay', { direction }),
}
