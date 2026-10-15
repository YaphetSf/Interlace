import { useEffect, useRef, useState } from 'react'
import { api } from './api'
import { PlaybackState, SubtitleStream } from './types/api'

// Kodi exposes delay as step actions; JSON-RPC cannot read the absolute offset.
const SUBTITLE_STEP = 0.1
const AUDIO_STEP = 0.025
const SUBTITLE_NUDGE_STEPS = [1, 5, 10] as const

const fmt = (s?: number): string => {
  s = Math.max(0, Math.floor(s || 0))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  const mm = String(m).padStart(2, '0')
  const ss = String(sec).padStart(2, '0')
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`
}

const subtitleLabel = (stream: SubtitleStream): string => {
  const name = !stream.name || stream.name === '(External)'
    ? `External ${stream.index + 1}`
    : stream.name
  return stream.language ? `${stream.language} · ${name}` : name
}

const errorMessage = (error: unknown, fallback: string): string => {
  if (!(error instanceof Error)) return fallback
  try {
    const body = JSON.parse(error.message)
    if (typeof body.detail === 'string') return body.detail
  } catch {
    // A network error or a plain-text response already has a readable message.
  }
  return error.message
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
  step: number;
  busy: boolean;
  onMinus: () => void;
  onPlus: () => void;
}

function DelayRow({ label, off, step, busy, onMinus, onPlus }: DelayRowProps) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-sm text-zinc-400">{label}</span>
      <div className="flex items-center gap-2">
        <button type="button" onClick={onMinus} disabled={busy} aria-label="Move audio earlier" className="w-9 h-9 rounded-lg bg-zinc-800 text-lg leading-none hover:bg-zinc-700 active:bg-sky-700 disabled:opacity-50 cursor-pointer">
          −
        </button>
        <span aria-live="polite" className="text-xs text-zinc-300 tabular-nums min-w-22 text-center">
          {off === 0 ? `${step} s / tap` : `${Math.abs(off * step).toFixed(3)} s ${off < 0 ? 'earlier' : 'later'} here`}
        </span>
        <button type="button" onClick={onPlus} disabled={busy} aria-label="Move audio later" className="w-9 h-9 rounded-lg bg-zinc-800 text-lg leading-none hover:bg-zinc-700 active:bg-sky-700 disabled:opacity-50 cursor-pointer">
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
  const [transportBusy, setTransportBusy] = useState(false)
  const [audOff, setAudOff] = useState<number>(0)
  const [audBusy, setAudBusy] = useState(false)
  const [audError, setAudError] = useState<string | null>(null)
  const [subtitleNudgeSteps, setSubtitleNudgeSteps] = useState<number>(5)
  const [subtitleDelaySteps, setSubtitleDelaySteps] = useState(0)
  const [subtitleDelayChanged, setSubtitleDelayChanged] = useState(false)
  const [subtitleDelayPending, setSubtitleDelayPending] = useState(0)
  const [subtitleDelayError, setSubtitleDelayError] = useState<string | null>(null)
  const [subtitleUploading, setSubtitleUploading] = useState(false)
  const [subtitleUploadError, setSubtitleUploadError] = useState<string | null>(null)
  const fileRef = useRef<string>('')
  const subtitleInputRef = useRef<HTMLInputElement>(null)
  const subtitleDelayBusyRef = useRef(false)
  const audioDelayBusyRef = useRef(false)

  const refresh = () =>
    api
      .player()
      .then((d) => {
        setErr(null)
        if (d.file && d.file !== fileRef.current) {
          fileRef.current = d.file
          setAudOff(0)
          setAudBusy(false)
          setAudError(null)
          setSubtitleDelaySteps(0)
          setSubtitleDelayChanged(false)
          setSubtitleDelayPending(0)
          setSubtitleDelayError(null)
        }
        setSt(d)
      })
      .catch((e: Error) => setErr(e.message))

  const togglePlayback = async () => {
    if (transportBusy) return
    setTransportBusy(true)
    try {
      await api.playpause()
      await refresh()
    } finally {
      setTransportBusy(false)
    }
  }

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
          togglePlayback()
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

  const addSubtitleFile = async (file: File) => {
    if (!st.file || subtitleUploading) return
    setSubtitleUploading(true)
    setSubtitleUploadError(null)
    try {
      const result = await api.uploadSubtitle(st.file, file)
      await refresh()
      if (!result.activated) {
        setSubtitleUploadError('File saved, but Kodi could not load it into this playback.')
      }
    } catch (e) {
      setSubtitleUploadError(e instanceof Error ? e.message : 'Could not add subtitle')
    } finally {
      setSubtitleUploading(false)
    }
  }

  const adjustSubtitleDelay = async (direction: 'minus' | 'plus') => {
    if (subtitleDelayBusyRef.current) return
    subtitleDelayBusyRef.current = true
    const file = fileRef.current
    setSubtitleDelayPending(subtitleNudgeSteps)
    setSubtitleDelayError(null)
    try {
      for (let step = 0; step < subtitleNudgeSteps; step++) {
        if (fileRef.current !== file) break
        const result = await api.subtitleDelay(direction)
        if (!result.ok) throw new Error('Kodi did not accept the subtitle adjustment')
        if (fileRef.current !== file) break
        setSubtitleDelaySteps((steps) => steps + (direction === 'minus' ? -1 : 1))
        setSubtitleDelayChanged(true)
        setSubtitleDelayPending((count) => count - 1)
      }
    } catch (error) {
      if (fileRef.current === file) {
        setSubtitleDelayError(`Could not move subtitles: ${errorMessage(error, 'Unknown error')}`)
      }
    } finally {
      subtitleDelayBusyRef.current = false
      if (fileRef.current === file) setSubtitleDelayPending(0)
    }
  }

  const adjustAudioDelay = async (direction: 'minus' | 'plus') => {
    if (audioDelayBusyRef.current) return
    audioDelayBusyRef.current = true
    const file = fileRef.current
    setAudBusy(true)
    setAudError(null)
    try {
      const result = await api.audioDelay(direction)
      if (!result.ok) throw new Error('Kodi did not accept the audio adjustment')
      if (fileRef.current === file) setAudOff((steps) => steps + (direction === 'minus' ? -1 : 1))
    } catch (error) {
      if (fileRef.current === file) setAudError(`Could not move audio: ${errorMessage(error, 'Unknown error')}`)
    } finally {
      audioDelayBusyRef.current = false
      if (fileRef.current === file) setAudBusy(false)
    }
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
          onClick={togglePlayback}
          disabled={transportBusy}
          className="w-16 h-16 rounded-full bg-sky-500 text-zinc-950 flex items-center justify-center hover:scale-105 active:scale-95 transition-all shadow-[0_4px_20px_rgba(14,165,233,0.3)] cursor-pointer disabled:opacity-60 disabled:hover:scale-100"
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
        <div className="flex items-center justify-between gap-3">
          <div className="text-sm text-zinc-400">Subtitle</div>
          {st.file?.startsWith('/') && (
            <>
              <input
                ref={subtitleInputRef}
                type="file"
                accept=".srt,.ass,.ssa,.vtt"
                className="hidden"
                onChange={(e) => {
                  const file = e.target.files?.[0]
                  e.target.value = ''
                  if (file) void addSubtitleFile(file)
                }}
              />
              <button
                type="button"
                disabled={subtitleUploading}
                onClick={() => subtitleInputRef.current?.click()}
                className="rounded-lg bg-zinc-800 px-3 py-2 text-sm text-zinc-200 hover:bg-zinc-700 disabled:opacity-60"
              >
                {subtitleUploading ? 'Adding...' : 'Add file'}
              </button>
            </>
          )}
        </div>
        {subtitleUploadError && <p role="alert" className="text-sm text-rose-400">{subtitleUploadError}</p>}
        <select
          value={st.subtitleenabled ? st.currentsubtitle?.index ?? '' : 'off'}
          onChange={(e) => api.setSubtitle(e.target.value === 'off' ? 'off' : parseInt(e.target.value, 10)).then(refresh)}
          className="w-full bg-zinc-800 rounded-lg px-3 py-2 text-sm outline-none"
        >
          <option value="off">Off</option>
          {st.subtitles?.map((s) => (
            <option key={s.index} value={s.index}>
              {subtitleLabel(s)}
            </option>
          ))}
        </select>
        <div className="flex items-center justify-between gap-3 pt-2">
          <span className="text-sm text-zinc-400">Adjust by</span>
          <div role="group" aria-label="Subtitle adjustment per tap" className="flex gap-1 rounded-lg bg-zinc-900 p-1">
            {SUBTITLE_NUDGE_STEPS.map((steps) => (
              <button
                key={steps}
                type="button"
                aria-pressed={subtitleNudgeSteps === steps}
                disabled={subtitleDelayPending > 0}
                onClick={() => setSubtitleNudgeSteps(steps)}
                className={`rounded-md px-3 py-1.5 text-xs tabular-nums transition cursor-pointer disabled:cursor-wait ${subtitleNudgeSteps === steps ? 'bg-sky-500 text-zinc-950 font-semibold' : 'text-zinc-400 hover:text-zinc-100 hover:bg-zinc-800'}`}
              >
                {(steps * SUBTITLE_STEP).toFixed(1)} s
              </button>
            ))}
          </div>
        </div>
        <div className="grid grid-cols-2 gap-2">
          <button
            type="button"
            onClick={() => void adjustSubtitleDelay('minus')}
            disabled={subtitleDelayPending > 0}
            className="min-h-24 rounded-xl border border-zinc-700 bg-zinc-800 px-3 py-3 text-left text-zinc-100 hover:border-sky-500 hover:bg-zinc-700 active:scale-[0.98] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-sky-400 disabled:opacity-50 disabled:cursor-wait transition cursor-pointer"
          >
            <span className="block text-sm font-medium">Audio before subtitle</span>
            <span className="mt-2 block text-xs text-sky-300 tabular-nums">← Subtitles {(subtitleNudgeSteps * SUBTITLE_STEP).toFixed(1)} s earlier</span>
          </button>
          <button
            type="button"
            onClick={() => void adjustSubtitleDelay('plus')}
            disabled={subtitleDelayPending > 0}
            className="min-h-24 rounded-xl border border-zinc-700 bg-zinc-800 px-3 py-3 text-left text-zinc-100 hover:border-sky-500 hover:bg-zinc-700 active:scale-[0.98] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-sky-400 disabled:opacity-50 disabled:cursor-wait transition cursor-pointer"
          >
            <span className="block text-sm font-medium">Subtitle before audio</span>
            <span className="mt-2 block text-xs text-sky-300 tabular-nums">Subtitles {(subtitleNudgeSteps * SUBTITLE_STEP).toFixed(1)} s later →</span>
          </button>
        </div>
        {(subtitleDelayPending > 0 || subtitleDelayChanged) && (
          <div role="status" aria-live="polite" className="rounded-lg border border-sky-500/30 bg-sky-500/10 px-3 py-2 text-sm text-sky-100 tabular-nums">
            {subtitleDelayPending > 0
              ? `Applying subtitle adjustment… ${subtitleDelayPending} step${subtitleDelayPending === 1 ? '' : 's'} left`
              : subtitleDelaySteps === 0
                ? 'No net change from this page'
                : `Subtitles moved ${Math.abs(subtitleDelaySteps * SUBTITLE_STEP).toFixed(1)} s ${subtitleDelaySteps < 0 ? 'earlier' : 'later'} from this page`}
            {subtitleDelayPending === 0 && st.speed === 0 && <span className="block text-sky-200/80">Paused · press Play to check sync</span>}
          </div>
        )}
        {subtitleDelayError && <p role="alert" className="rounded-lg border border-rose-500/30 bg-rose-500/10 px-3 py-2 text-sm text-rose-300">{subtitleDelayError}</p>}
      </div>

      <DelayRow
        label="Audio Delay"
        off={audOff}
        step={AUDIO_STEP}
        busy={audBusy}
        onMinus={() => void adjustAudioDelay('minus')}
        onPlus={() => void adjustAudioDelay('plus')}
      />
      {audError && <p role="alert" className="text-sm text-rose-400">{audError}</p>}
    </div>
  )
}
