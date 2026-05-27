import React, { useEffect, useState } from 'react'
import { api } from './api'
import { DownloadItem } from './types/api'

const fmtSize = (b: number): string => (!b ? '—' : b > 1e9 ? (b / 1e9).toFixed(2) + ' GB' : (b / 1e6).toFixed(0) + ' MB')
const fmtSpeed = (b: number): string => (b > 1e6 ? (b / 1e6).toFixed(1) + ' MB/s' : (b / 1e3).toFixed(0) + ' KB/s')

const STATUS: Record<DownloadItem['status'], string> = {
  active: 'Downloading',
  waiting: 'Queued',
  paused: 'Paused',
  complete: 'Completed',
  error: 'Error',
  removed: 'Removed',
}

export default function Downloads() {
  const [items, setItems] = useState<DownloadItem[]>([])
  const [uri, setUri] = useState<string>('')
  const [drag, setDrag] = useState<boolean>(false)
  const [err, setErr] = useState<string | null>(null)
  const [adding, setAdding] = useState<boolean>(false)

  const refresh = () =>
    api
      .downloads()
      .then((d) => {
        setItems(d)
        setErr(null)
      })
      .catch((e: Error) => setErr(e.message))

  useEffect(() => {
    refresh()
    const id = setInterval(refresh, 1500)
    return () => clearInterval(id)
  }, [])

  const add = async () => {
    const v = uri.trim()
    if (!v) return
    setAdding(true)
    try {
      await api.addUri(v)
      setUri('')
      refresh()
    } catch (e: any) {
      alert('Failed to add: ' + e.message)
    } finally {
      setAdding(false)
    }
  }

  const onDrop = async (e: React.DragEvent<HTMLDivElement>) => {
    e.preventDefault()
    setDrag(false)
    const f = e.dataTransfer.files?.[0]
    if (f && f.name.toLowerCase().endsWith('.torrent')) {
      try {
        await api.addTorrent(f)
        refresh()
      } catch (err: any) {
        alert('Failed to add: ' + err.message)
      }
    }
  }

  return (
    <div className="p-4 md:p-6 w-full max-w-5xl mx-auto space-y-5">
      {err && (
        <div className="text-rose-455 text-xs break-all bg-rose-500/5 border border-rose-500/10 rounded-2xl p-4 font-semibold">
          {err}
        </div>
      )}

      {/* Grid container: Split on tablet/desktop */}
      <div className="grid grid-cols-1 md:grid-cols-[290px_1fr] lg:grid-cols-[330px_1fr] gap-6 items-start">
        
        {/* Left Column: Create Download Task (Sticky Panel) */}
        <div
          onDragOver={(e: React.DragEvent<HTMLDivElement>) => {
            e.preventDefault()
            setDrag(true)
          }}
          onDragLeave={() => setDrag(false)}
          onDrop={onDrop}
          className={`relative overflow-hidden border rounded-2xl p-5 space-y-4.5 transition-all duration-350 bg-zinc-900/20 backdrop-blur-sm shadow-[inset_0_1px_0_rgba(255,255,255,0.05)] md:sticky md:top-20 ${
            drag
              ? 'border-sky-400 bg-sky-950/20 scale-[1.01] shadow-[0_0_20px_rgba(14,165,233,0.15)]'
              : 'border-zinc-900 hover:border-zinc-800'
          }`}
        >
          <div className="space-y-1 text-center md:text-left">
            <h2 className="text-xs font-bold tracking-wider text-zinc-300 uppercase flex items-center justify-center md:justify-start gap-1.5 select-none">
              <svg className="w-4 h-4 text-sky-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v6m3-3H9m12 0a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              Create Task
            </h2>
            <p className="text-[10px] text-zinc-500 leading-relaxed">
              Paste magnet link, HTTP/FTP URL, or drop a torrent file below to begin downloading.
            </p>
          </div>

          {/* Input Bar */}
          <div className="space-y-2 relative z-10">
            <input
              value={uri}
              onChange={(e) => setUri(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && add()}
              placeholder="Paste magnet:?xt=... or URL"
              className="w-full bg-zinc-950 border border-zinc-900 focus:border-sky-500/80 rounded-xl px-3 py-2.5 text-xs text-zinc-200 outline-none transition-all focus:ring-1 focus:ring-sky-500/30 placeholder-zinc-650 font-sans"
              disabled={adding}
            />
            <button
              onClick={add}
              disabled={adding}
              className="w-full py-2.5 rounded-xl bg-gradient-to-r from-sky-400 to-indigo-500 text-zinc-950 text-xs font-bold transition-all hover:scale-102 active:scale-98 disabled:opacity-50 flex items-center justify-center cursor-pointer shadow-[0_4px_15px_rgba(14,165,233,0.15)]"
            >
              {adding ? 'Adding...' : 'Add Link'}
            </button>
          </div>

          {/* Dashed dropzone inside card */}
          <div
            className={`border border-dashed rounded-xl py-6 flex flex-col items-center justify-center gap-1.5 text-[10px] transition-colors duration-300 text-center px-4 ${
              drag ? 'border-sky-400/40 text-sky-400 font-semibold bg-sky-950/10' : 'border-zinc-900 text-zinc-500'
            }`}
          >
            {drag ? (
              <>
                <svg className="w-5 h-5 animate-bounce shrink-0 text-sky-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M19.5 8.25l-7.5 7.5-7.5-7.5" />
                </svg>
                <span>Release to Parse Torrent</span>
              </>
            ) : (
              <>
                <svg className="w-5 h-5 shrink-0 text-zinc-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M9 13h6m-3-3v6m-9 1V4a2 2 0 012-2h6l2 2h6a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z" />
                </svg>
                <span>Drag & drop .torrent here</span>
              </>
            )}
          </div>
        </div>

        {/* Right Column: Download Queue */}
        <div className="space-y-3">
          <div className="flex justify-between items-center px-1">
            <span className="text-xs font-semibold tracking-wider text-zinc-400 uppercase select-none">
              Download Queue
            </span>
            <span className="text-[10px] text-zinc-550 font-bold uppercase tracking-wider bg-zinc-950/40 border border-zinc-900/65 px-2 py-0.5 rounded-lg tabular-nums">
              {items.length} {items.length === 1 ? 'task' : 'tasks'}
            </span>
          </div>

          {items.length === 0 && (
            <div className="flex flex-col items-center justify-center py-16 space-y-3 border border-zinc-900/60 rounded-3xl bg-zinc-900/10 backdrop-blur-sm">
              <div className="w-12 h-12 rounded-xl bg-zinc-950 border border-zinc-900 flex items-center justify-center text-zinc-600 shadow-inner">
                <svg className="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
                </svg>
              </div>
              <p className="text-xs text-zinc-500 font-medium">No download tasks actively queued</p>
            </div>
          )}

          <div className="space-y-3">
            {items.map((d) => {
              const isActive = d.status === 'active'
              const isPaused = d.status === 'paused'
              const isComplete = d.status === 'complete'
              const isError = d.status === 'error'

              return (
                <div
                  key={d.gid}
                  className="bg-zinc-900/40 border border-zinc-900/60 rounded-2xl p-4 space-y-3 hover:scale-[1.005] hover:border-zinc-850 transition-all duration-300 shadow-sm"
                >
                  {/* Task Header */}
                  <div className="flex justify-between items-start gap-3 min-w-0">
                    <span className="text-sm font-semibold text-zinc-200 truncate flex-1">
                      {d.name || 'Parsing metadata...'}
                    </span>
                    <span
                      className={`text-[9px] tracking-wider uppercase px-2 py-0.5 rounded-full font-bold shrink-0 ${
                        isComplete
                          ? 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/20'
                          : isPaused
                          ? 'bg-amber-500/10 text-amber-400 border border-amber-500/20'
                          : isError
                          ? 'bg-rose-500/10 text-rose-455 border border-rose-500/20'
                          : 'bg-sky-500/10 text-sky-400 border border-sky-500/20'
                      }`}
                    >
                      {STATUS[d.status] || d.status}
                    </span>
                  </div>

                  {/* Progress Slider */}
                  <div className="space-y-1">
                    <div className="h-1.5 w-full bg-zinc-800 rounded-full overflow-hidden">
                      <div
                        className={`h-full rounded-full transition-all duration-300 bg-gradient-to-r ${
                          isComplete
                            ? 'from-emerald-500 to-teal-500'
                            : isError
                            ? 'from-rose-500 to-red-500'
                            : 'from-sky-500 to-indigo-500 shadow-[0_0_8px_rgba(14,165,233,0.3)]'
                        }`}
                        style={{ width: `${d.progress}%` }}
                      />
                    </div>
                    
                    {/* Stats label & Actions */}
                    <div className="flex justify-between items-center text-xs text-zinc-400 pt-0.5">
                      <span className="tabular-nums text-[11px] text-zinc-550">
                        <span className="font-semibold text-zinc-400">{d.progress}%</span>
                        {' · '}
                        {fmtSize(d.completed)} / {fmtSize(d.total)}
                        {isActive ? (
                          <span className="text-sky-400 font-medium inline-flex items-center gap-1 ml-1.5">
                            <span>·</span>
                            <svg className="w-3 h-3 fill-current" viewBox="0 0 24 24">
                              <path d="M13 10V3L4 14h7v7l9-11h-7z" />
                            </svg>
                            <span>{fmtSpeed(d.speed)}</span>
                          </span>
                        ) : (
                          ''
                        )}
                      </span>
                      
                      {/* Action Pill Controls */}
                      <div className="flex gap-2 shrink-0">
                        {isActive && (
                          <button
                            onClick={() => api.pause(d.gid).then(refresh)}
                            className="px-2.5 py-1 rounded-lg bg-zinc-950 hover:bg-zinc-900 border border-zinc-900 text-zinc-450 hover:text-amber-400 transition-colors text-[10px] font-bold cursor-pointer"
                          >
                            Pause
                          </button>
                        )}
                        {isPaused && (
                          <button
                            onClick={() => api.resume(d.gid).then(refresh)}
                            className="px-2.5 py-1 rounded-lg bg-zinc-950 hover:bg-sky-950/20 border border-zinc-900 hover:border-sky-900/30 text-zinc-450 hover:text-sky-400 transition-colors text-[10px] font-bold cursor-pointer"
                          >
                            Resume
                          </button>
                        )}
                        <button
                          onClick={() => api.remove(d.gid).then(refresh)}
                          className="px-2.5 py-1 rounded-lg bg-zinc-950 hover:bg-rose-950/20 border border-zinc-900 hover:border-rose-900/30 text-zinc-450 hover:text-rose-455 transition-colors text-[10px] font-bold cursor-pointer"
                        >
                          Delete
                        </button>
                      </div>
                    </div>
                  </div>
                  
                  {d.error && (
                    <div className="text-rose-455 text-[10px] font-medium break-all bg-rose-500/5 rounded-lg p-2 border border-rose-500/10">
                      {d.error}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        </div>
      </div>
    </div>
  )
}
