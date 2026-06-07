import { useState } from 'react'
import { api } from './api'

interface StreamProps {
  onPlay: () => void;
}

export default function Stream({ onPlay }: StreamProps) {
  const [url, setUrl] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const play = async () => {
    const value = url.trim()
    if (!value || loading) return

    setLoading(true)
    setError(null)
    try {
      await api.stream(value)
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

        <p className="text-[10px] leading-relaxed text-zinc-600">
          DRM-protected services such as Netflix and Disney+ are not supported. Website support depends on yt-dlp,
          and some videos may require login or be unavailable in the server's region.
        </p>
      </div>
    </div>
  )
}
