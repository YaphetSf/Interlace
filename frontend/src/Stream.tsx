import { useState } from 'react'
import { api } from './api'

interface StreamProps {
  onPlay: () => void;
}

export default function Stream({ onPlay }: StreamProps) {
  const [url, setUrl] = useState('')
  const [quality, setQuality] = useState<'compatible' | '720p' | '1080p'>('1080p')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [result, setResult] = useState<string | null>(null)

  const play = async () => {
    const value = url.trim()
    if (!value || loading) return

    setLoading(true)
    setError(null)
    setResult(null)
    try {
      const response = await api.stream(value, quality)
      setResult(`${response.quality} via ${response.source}`)
      onPlay()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="p-4 md:p-6 w-full max-w-2xl mx-auto">
      <div className="relative overflow-hidden border border-zinc-900 rounded-3xl p-6 md:p-8 bg-zinc-900/20 backdrop-blur-sm shadow-[inset_0_1px_0_rgba(255,255,255,0.05)] space-y-6">
        <div className="space-y-2">
          <div className="w-12 h-12 rounded-2xl bg-sky-500/10 border border-sky-500/20 flex items-center justify-center text-sky-400">
            <svg className="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.8}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M15.59 14.37a6 6 0 01-8.49-8.49m8.49 8.49a6 6 0 00-8.49-8.49m8.49 8.49L21 19.78m-13.9-13.9L2 1m7.5 10.5l5-3-5-3v6z" />
            </svg>
          </div>
          <h2 className="text-lg font-semibold text-zinc-100">Play an online video</h2>
          <p className="text-xs leading-relaxed text-zinc-500">
            Paste a YouTube or other supported website URL, or a direct MP4, WebM, HLS, or DASH stream.
            Interlace resolves it and asks Kodi to play it without downloading the full video first.
          </p>
        </div>

        <div className="space-y-3">
          <input
            type="url"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && play()}
            placeholder="https://www.youtube.com/watch?v=..."
            autoCapitalize="none"
            autoCorrect="off"
            disabled={loading}
            className="w-full bg-zinc-950 border border-zinc-800 focus:border-sky-500/80 rounded-xl px-4 py-3 text-sm text-zinc-200 outline-none transition-all focus:ring-1 focus:ring-sky-500/30 placeholder-zinc-650 disabled:opacity-60"
          />
          <div className="grid grid-cols-3 gap-2">
            {[
              ['compatible', 'Compatible'],
              ['720p', '720p'],
              ['1080p', '1080p'],
            ].map(([value, label]) => (
              <button
                key={value}
                type="button"
                onClick={() => setQuality(value as typeof quality)}
                disabled={loading}
                className={`rounded-xl border px-2 py-2 text-xs font-semibold transition-colors cursor-pointer ${
                  quality === value
                    ? 'border-sky-500/60 bg-sky-500/10 text-sky-300'
                    : 'border-zinc-850 bg-zinc-950/60 text-zinc-500 hover:text-zinc-300'
                }`}
              >
                {label}
              </button>
            ))}
          </div>
          <button
            onClick={play}
            disabled={loading || !url.trim()}
            className="w-full py-3 rounded-xl bg-gradient-to-r from-sky-400 to-indigo-500 text-zinc-950 text-sm font-bold transition-all hover:scale-[1.01] active:scale-[0.99] disabled:opacity-50 disabled:hover:scale-100 cursor-pointer"
          >
            {loading ? 'Resolving stream...' : 'Play on Kodi'}
          </button>
        </div>

        {error && (
          <div className="text-rose-400 text-xs break-all bg-rose-500/5 border border-rose-500/15 rounded-xl p-3">
            {error}
          </div>
        )}

        {result && <div className="text-xs text-emerald-400">{result}</div>}

        <p className="text-[10px] leading-relaxed text-zinc-600">
          720p and 1080p use ffmpeg to combine separate video and audio streams without re-encoding. Compatible mode
          works without ffmpeg but may be limited to 360p. DRM-protected services are not supported.
        </p>
      </div>
    </div>
  )
}
