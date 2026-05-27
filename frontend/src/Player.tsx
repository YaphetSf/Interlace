import { useEffect, useRef, useState } from 'react'
import { api } from './api'
import { PlaybackState } from './types/api'

// Kodi exposes subtitle/audio delay only as +/- step actions over JSON-RPC —
// the absolute value can't be read, so we estimate it client-side. ~0.1s/step.
const STEP = 0.1

const fmt = (s?: number): string => {
  s = Math.max(0, Math.floor(s || 0))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  const mm = String(m).padStart(2, '0')
  const ss = String(sec).padStart(2, '0')
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`
}

interface VolumeRowProps {
  st: PlaybackState;
  onVol: (v: number) => void;
  onMute: (m: boolean) => void;
}

function VolumeRow({ st, onVol, onMute }: VolumeRowProps) {
  return (
    <div className="flex items-center gap-3">
      <button onClick={() => onMute(!st.muted)} className="text-zinc-400 hover:text-zinc-200 transition-colors w-8 shrink-0 flex items-center justify-start">
        {st.muted ? (
          <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M17.25 9.75L19.5 12m0 0l2.25 2.25M19.5 12l2.25-2.25M19.5 12l-2.25 2.25m-10.5-6L4.5 9H1.5v6h3l4.5 3V6z" />
          </svg>
        ) : (
          <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M19.114 5.636a9 9 0 010 12.728M16.463 8.288a5.25 5.25 0 010 7.424M6.75 8.25l4.72-4.72a.75.75 0 011.28.53v15.88a.75.75 0 01-1.28.53l-4.72-4.72H4.51c-.88 0-1.704-.507-1.938-1.354A9.01 9.01 0 012.25 12c0-.83.112-1.633.322-2.396C2.806 8.756 3.63 8.25 4.51 8.25H6.75z" />
          </svg>
        )}
      </button>
      <input
        type="range"
        min="0"
        max="100"
        value={st.muted ? 0 : st.volume ?? 0}
        onChange={(e) => onVol(parseInt(e.target.value, 10))}
        className="flex-1 accent-sky-500"
      />
      <span className="text-xs text-zinc-400 w-8 text-right tabular-nums">{st.volume ?? 0}</span>
    </div>
  )
}

interface StreamSelectProps<T> {
  label: string;
  streams?: T[];
  current?: number;
  render: (stream: T) => string;
  onChange: (index: number) => void;
}

function StreamSelect<T extends { index: number }>({ label, streams, current, render, onChange }: StreamSelectProps<T>) {
  if (!streams || streams.length === 0) return null
  return (
    <div className="space-y-2">
      <div className="text-sm text-zinc-400">{label}</div>
      <select
        value={current ?? ''}
        onChange={(e) => onChange(parseInt(e.target.value, 10))}
        className="w-full bg-zinc-800 rounded-lg px-3 py-2 text-sm outline-none"
      >
        {streams.map((s) => (
          <option key={s.index} value={s.index}>
            {render(s)}
          </option>
        ))}
      </select>
    </div>
  )
}

interface DelayRowProps {
  label: string;
  off: number;
  onMinus: () => void;
  onPlus: () => void;
  onReset: () => void;
}

function DelayRow({ label, off, onMinus, onPlus, onReset }: DelayRowProps) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-sm text-zinc-400">{label}</span>
      <div className="flex items-center gap-2">
        <button onClick={onMinus} className="w-9 h-9 rounded-lg bg-zinc-800 text-lg leading-none">
          −
        </button>
        <button
          onClick={onReset}
          title="Estimated value. Click to reset (does not affect Kodi)"
          className="text-xs text-zinc-300 tabular-nums w-14 text-center"
        >
          ≈ {(off * STEP).toFixed(1)}s
        </button>
        <button onClick={onPlus} className="w-9 h-9 rounded-lg bg-zinc-800 text-lg leading-none">
          +
        </button>
      </div>
    </div>
  )
}

interface PlayerProps {
  active: boolean;
}

export default function Player({ active }: PlayerProps) {
  const [st, setSt] = useState<PlaybackState | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [seeking, setSeeking] = useState<number | null>(null)
  const [subOff, setSubOff] = useState<number>(0)
  const [audOff, setAudOff] = useState<number>(0)
  const fileRef = useRef<string>('')

  const refresh = () =>
    api
      .player()
      .then((d) => {
        setErr(null)
        if (d.file && d.file !== fileRef.current) {
          fileRef.current = d.file
          setSubOff(0)
          setAudOff(0)
        }
        setSt(d)
      })
      .catch((e: Error) => setErr(e.message))

  useEffect(() => {
    refresh()
    const id = setInterval(() => {
      if (seeking === null) refresh()
    }, 1000)
    return () => clearInterval(id)
  }, [seeking])

  useEffect(() => {
    if (!active || !st || !st.active) return

    const pct = seeking !== null ? seeking : st.percentage || 0

    const handleKeyDown = (e: KeyboardEvent) => {
      if (['INPUT', 'TEXTAREA', 'SELECT'].includes((e.target as HTMLElement).tagName)) {
        return
      }

      let prevented = true
      switch (e.key) {
        case ' ':
          api.playpause().then(refresh)
          break
        case 'ArrowLeft':
          api.seek(Math.max(0, pct - 5)).then(refresh)
          break
        case 'ArrowRight':
          api.seek(Math.min(100, pct + 5)).then(refresh)
          break
        case 'ArrowUp':
          api.setVolume(Math.min(100, (st.volume ?? 0) + 5)).then(refresh)
          break
        case 'ArrowDown':
          api.setVolume(Math.max(0, (st.volume ?? 0) - 5)).then(refresh)
          break
        case 'm':
        case 'M':
          api.setMute(!st.muted).then(refresh)
          break
        default:
          prevented = false
          break
      }

      if (prevented) {
        e.preventDefault()
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => {
      window.removeEventListener('keydown', handleKeyDown)
    }
  }, [active, st, seeking, refresh])

  if (err) return <div className="p-6 text-rose-400 break-all">Failed to connect to Kodi: {err}</div>
  if (!st) return <div className="p-6 text-zinc-400">Loading...</div>

  if (!st.active) {
    return (
      <div className="p-6 max-w-2xl mx-auto space-y-6 px-4 md:px-6">
        <div className="text-center text-zinc-400">
          <div className="w-16 h-16 rounded-2xl bg-zinc-900 border border-zinc-800 flex items-center justify-center mx-auto mb-4 shadow-inner text-zinc-500">
            <svg className="w-8 h-8" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 20.25h12m-7.5-3v3m3-3v3m-10.125-3h17.25c.621 0 1.125-.504 1.125-1.125V4.875c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 1.125v11.25c0 .621.504 1.125 1.125 1.125z" />
            </svg>
          </div>
          Nothing is currently playing on the TV.
          <br />
          Go to the "Library" tab to select a video.
        </div>
        <VolumeRow
          st={st}
          onVol={(v) => api.setVolume(v).then(refresh)}
          onMute={(m) => api.setMute(m).then(refresh)}
        />
      </div>
    )
  }

  const pct = seeking !== null ? seeking : st.percentage || 0
  const curTime = st.totaltime ? (pct / 100) * st.totaltime : st.time

  const doSeek = (v: number) => {
    setSeeking(null)
    api.seek(v).then(refresh)
  }

  return (
    <div className="p-4 space-y-5 max-w-2xl mx-auto px-4 md:px-6">
      <div>
        <h2 className="text-xl font-semibold truncate">{st.title || st.file?.split('/').pop()}</h2>
        <div className="text-xs text-zinc-500">{st.speed === 0 ? 'Paused' : 'Playing'}</div>
      </div>

      {/* seek bar */}
      <div className="space-y-1">
        <input
          type="range"
          min="0"
          max="100"
          step="0.1"
          value={pct}
          onChange={(e) => setSeeking(parseFloat(e.target.value))}
          onMouseUp={(e) => doSeek(parseFloat((e.target as HTMLInputElement).value))}
          onTouchEnd={(e) => doSeek(parseFloat((e.target as HTMLInputElement).value))}
          className="w-full accent-sky-500"
        />
        <div className="flex justify-between text-xs text-zinc-400 tabular-nums">
          <span>{fmt(curTime)}</span>
          <span>{fmt(st.totaltime)}</span>
        </div>
      </div>

      {/* transport */}
      <div className="flex items-center justify-center gap-5">
        <button
          onClick={() => api.seek(Math.max(0, pct - 5)).then(refresh)}
          className="w-10 h-10 rounded-xl bg-zinc-900 border border-zinc-800 flex items-center justify-center text-zinc-400 hover:text-zinc-200 transition-colors active:scale-95 cursor-pointer shadow-sm"
          title="Rewind 5%"
        >
          <svg className="w-5 h-5 fill-current" viewBox="0 0 24 24">
            <path d="M11 18V6l-8.5 6 8.5 6zm.5-6l8.5 6V6l-8.5 6z" />
          </svg>
        </button>
        <button
          onClick={() => api.playpause().then(refresh)}
          className="w-16 h-16 rounded-full bg-sky-500 text-zinc-950 flex items-center justify-center hover:scale-105 active:scale-95 transition-all shadow-[0_4px_20px_rgba(14,165,233,0.3)] cursor-pointer"
          title={st.speed === 0 ? "Play" : "Pause"}
        >
          {st.speed === 0 ? (
            <svg className="w-7 h-7 fill-current ml-0.5" viewBox="0 0 24 24">
              <path d="M8 5v14l11-7z" />
            </svg>
          ) : (
            <svg className="w-7 h-7 fill-current" viewBox="0 0 24 24">
              <path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z" />
            </svg>
          )}
        </button>
        <button
          onClick={() => api.seek(Math.min(100, pct + 5)).then(refresh)}
          className="w-10 h-10 rounded-xl bg-zinc-900 border border-zinc-800 flex items-center justify-center text-zinc-400 hover:text-zinc-200 transition-colors active:scale-95 cursor-pointer shadow-sm"
          title="Fast Forward 5%"
        >
          <svg className="w-5 h-5 fill-current" viewBox="0 0 24 24">
            <path d="M4 18l8.5-6L4 6v12zm9-12v12l8.5-6L13 6z" />
          </svg>
        </button>
        <button 
          onClick={() => api.stop().then(refresh)} 
          className="w-10 h-10 rounded-xl bg-zinc-900 border border-zinc-800 flex items-center justify-center text-rose-400 hover:text-rose-300 transition-colors active:scale-95 cursor-pointer shadow-sm"
          title="Stop"
        >
          <svg className="w-4 h-4 fill-current" viewBox="0 0 24 24">
            <path d="M6 6h12v12H6z" />
          </svg>
        </button>
      </div>

      <VolumeRow
        st={st}
        onVol={(v) => api.setVolume(v).then(refresh)}
        onMute={(m) => api.setMute(m).then(refresh)}
      />

      <StreamSelect
        label="Audio Track"
        streams={st.audiostreams}
        current={st.currentaudiostream?.index}
        render={(s) =>
          `${s.language || '?'} · ${s.name || 'Track ' + s.index}${s.codec ? ' (' + s.codec + ')' : ''}`
        }
        onChange={(i) => api.setAudio(i).then(refresh)}
      />

      {st.videostreams && st.videostreams.length > 1 && (
        <StreamSelect
          label="Video Stream"
          streams={st.videostreams}
          current={st.currentvideostream?.index}
          render={(s) =>
            `${s.name || 'Stream ' + s.index}${s.width ? ` ${s.width}x${s.height}` : ''}${
              s.codec ? ' (' + s.codec + ')' : ''
            }`
          }
          onChange={(i) => api.setVideo(i).then(refresh)}
        />
      )}

      {/* subtitles */}
      <div className="space-y-2">
        <div className="text-sm text-zinc-400">Subtitle</div>
        <select
          value={st.subtitleenabled ? st.currentsubtitle?.index ?? '' : 'off'}
          onChange={(e) => api.setSubtitle(e.target.value === 'off' ? 'off' : parseInt(e.target.value, 10)).then(refresh)}
          className="w-full bg-zinc-800 rounded-lg px-3 py-2 text-sm outline-none"
        >
          <option value="off">Off</option>
          {st.subtitles?.map((s) => (
            <option key={s.index} value={s.index}>
              {(s.language || '?') + ' · ' + (s.name || 'Subtitle ' + s.index)}
            </option>
          ))}
        </select>
        <DelayRow
          label="Subtitle Delay"
          off={subOff}
          onMinus={() => {
            api.subtitleDelay('minus')
            setSubOff((o) => o - 1)
          }}
          onPlus={() => {
            api.subtitleDelay('plus')
            setSubOff((o) => o + 1)
          }}
          onReset={() => setSubOff(0)}
        />
      </div>

      <DelayRow
        label="Audio Delay"
        off={audOff}
        onMinus={() => {
          api.audioDelay('minus')
          setAudOff((o) => o - 1)
        }}
        onPlus={() => {
          api.audioDelay('plus')
          setAudOff((o) => o + 1)
        }}
        onReset={() => setAudOff(0)}
      />
    </div>
  )
}
