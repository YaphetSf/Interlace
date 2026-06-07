import { useState } from 'react'
import Library from './Library'
import Downloads from './Downloads'
import Player from './Player'
import Stream from './Stream'
import { api } from './api'
import { UploadTask } from './types/api'

interface TabItem {
  id: 'library' | 'downloads' | 'stream' | 'player';
  label: string;
}

const TABS: TabItem[] = [
  { id: 'library', label: 'Library' },
  { id: 'downloads', label: 'Downloads' },
  { id: 'stream', label: 'Stream' },
  { id: 'player', label: 'Player' },
]

function TabIcon({ id, className }: { id: string; className?: string }) {
  if (id === 'library') {
    return (
      <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
        <path strokeLinecap="round" strokeLinejoin="round" d="M4 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2V6zM14 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2V6zM4 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2v-2zM14 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2v-2z" />
      </svg>
    )
  }
  if (id === 'downloads') {
    return (
      <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
        <path strokeLinecap="round" strokeLinejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
      </svg>
    )
  }
  if (id === 'stream') {
    return (
      <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
        <path strokeLinecap="round" strokeLinejoin="round" d="M8.25 6.75h7.5m-7.5 3h7.5m-10.5 3h13.5A2.25 2.25 0 0121 15v3.75A2.25 2.25 0 0118.75 21H5.25A2.25 2.25 0 013 18.75V15a2.25 2.25 0 012.25-2.25z" />
        <path strokeLinecap="round" strokeLinejoin="round" d="M10 15.75v2.5l2.5-1.25L10 15.75zM6 3v3m12-3v3" />
      </svg>
    )
  }
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z" />
      <path strokeLinecap="round" strokeLinejoin="round" d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
    </svg>
  )
}

export default function App() {
  const [tab, setTab] = useState<'library' | 'downloads' | 'stream' | 'player'>('library')
  const [uploads, setUploads] = useState<UploadTask[]>([])
  const [showUploadsPanel, setShowUploadsPanel] = useState<boolean>(false)

  const uploadFiles = (filesList: File[] | FileList, currentPath: string) => {
    const filesArray = Array.from(filesList)
    const newUploads = filesArray.map((file) => ({
      id: Math.random().toString(36).substring(2, 9),
      name: file.webkitRelativePath || file.name,
      size: file.size,
      progress: 0,
      status: 'uploading' as const,
      error: null,
    }))

    setUploads((prev) => [...newUploads, ...prev])
    setShowUploadsPanel(true)

    newUploads.forEach((uploadItem, idx) => {
      const file = filesArray[idx]

      api
        .upload(file, currentPath, (progress) => {
          setUploads((prev) =>
            prev.map((up) => (up.id === uploadItem.id ? { ...up, progress } : up))
          )
        })
        .then(() => {
          setUploads((prev) =>
            prev.map((up) =>
              up.id === uploadItem.id ? { ...up, status: 'done', progress: 100 } : up
            )
          )
          // Automatically clear successful upload notification after 5 seconds
          setTimeout(() => {
            setUploads((prev) => prev.filter((up) => up.id !== uploadItem.id))
          }, 5000)
        })
        .catch((e: Error) => {
          setUploads((prev) =>
            prev.map((up) =>
              up.id === uploadItem.id ? { ...up, status: 'error', error: e.message } : up
            )
          )
        })
    })
  }

  const uploadSubtitle = (videoPath: string, file: File, videoName: string) => {
    const uploadId = Math.random().toString(36).substring(2, 9)
    const newUpload: UploadTask = {
      id: uploadId,
      name: `Subtitle: ${file.name} ➔ ${videoName}`,
      size: file.size,
      progress: 0,
      status: 'uploading' as const,
      error: null,
    }

    setUploads((prev) => [newUpload, ...prev])
    setShowUploadsPanel(true)

    api
      .uploadSubtitle(videoPath, file, (progress) => {
        setUploads((prev) =>
          prev.map((up) => (up.id === uploadId ? { ...up, progress } : up))
        )
      })
      .then(() => {
        setUploads((prev) =>
          prev.map((up) =>
            up.id === uploadId ? { ...up, status: 'done', progress: 100 } : up
          )
        )
        // Automatically clear successful upload notification after 5 seconds
        setTimeout(() => {
          setUploads((prev) => prev.filter((up) => up.id !== uploadId))
        }, 5000)
      })
      .catch((e: Error) => {
        setUploads((prev) =>
          prev.map((up) =>
            up.id === uploadId ? { ...up, status: 'error', error: e.message } : up
          )
        )
      })
  }

  const activeUploadsCount = uploads.filter((up) => up.status === 'uploading').length

  return (
    <div className="min-h-dvh bg-transparent text-zinc-100 flex flex-col font-sans antialiased">
      <header className="px-5 py-3.5 border-b border-zinc-900/60 sticky top-0 bg-zinc-950/80 backdrop-blur-md z-20 flex items-center justify-between shadow-[0_1px_10px_rgba(0,0,0,0.3)]">
        <h1 className="text-base font-bold tracking-wider uppercase bg-gradient-to-r from-sky-400 via-sky-300 to-indigo-400 bg-clip-text text-transparent select-none">
          Interlace Console
        </h1>
        
        <div className="flex items-center gap-4 relative">
          {/* Upload Status Badge / Popover Trigger */}
          {uploads.length > 0 && (
            <div className="relative">
              <button
                onClick={() => setShowUploadsPanel(!showUploadsPanel)}
                className="p-1.5 rounded-lg bg-zinc-900 border border-zinc-800 hover:border-zinc-700 text-zinc-400 hover:text-sky-400 transition-all flex items-center justify-center cursor-pointer shadow-sm relative active:scale-95"
                title="View Uploads"
              >
                <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1M12 12V3m0 0L8.5 6.5M12 3l3.5 3.5" />
                </svg>
                {activeUploadsCount > 0 && (
                  <span className="absolute -top-1 -right-1 flex h-4 w-4 items-center justify-center rounded-full bg-sky-500 text-[9px] font-bold text-zinc-950 animate-pulse">
                    {activeUploadsCount}
                  </span>
                )}
              </button>

              {/* Absolute Dropdown Popover */}
              {showUploadsPanel && (
                <div className="absolute right-0 top-11 w-72 bg-zinc-950/95 backdrop-blur-lg border border-zinc-900 rounded-2xl p-3.5 shadow-2xl z-50 space-y-2.5 text-left">
                  <div className="flex justify-between items-center px-0.5">
                    <h3 className="text-xs font-bold text-zinc-400">Upload Status</h3>
                    <button
                      onClick={() => {
                        setUploads([])
                        setShowUploadsPanel(false)
                      }}
                      className="text-[10px] text-zinc-500 hover:text-rose-400 transition-colors font-semibold cursor-pointer"
                    >
                      Clear All
                    </button>
                  </div>
                  <div className="space-y-2 max-h-60 overflow-y-auto pr-0.5 scrollbar-thin">
                    {uploads.map((up) => (
                      <div
                        key={up.id}
                        className="bg-zinc-900/30 rounded-xl p-2.5 border border-zinc-900/60 space-y-1 shadow-sm"
                      >
                        <div className="flex justify-between items-center gap-2 min-w-0">
                          <span className="text-[11px] text-zinc-300 truncate font-semibold flex-1">
                            {up.name}
                          </span>
                          <span
                            className={`text-[8px] tracking-wider uppercase px-1.5 py-0.5 rounded-full font-bold ${
                              up.status === 'done'
                                ? 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/20'
                                : up.status === 'error'
                                ? 'bg-rose-500/10 text-rose-400 border border-rose-500/20'
                                : 'bg-sky-500/10 text-sky-400 border border-sky-500/20 animate-pulse'
                            }`}
                          >
                            {up.status === 'done'
                              ? '✓ Done'
                              : up.status === 'error'
                              ? '✕ Fail'
                              : `${up.progress}%`}
                          </span>
                        </div>

                        {up.status === 'uploading' && (
                          <div className="h-1 w-full bg-zinc-950 rounded-full overflow-hidden">
                            <div
                              className="h-full bg-gradient-to-r from-sky-500 to-indigo-500 rounded-full transition-all duration-300 ease-out"
                              style={{ width: `${up.progress}%` }}
                            />
                          </div>
                        )}

                        {up.status === 'error' && (
                          <p className="text-[9px] text-rose-400 mt-0.5 font-medium break-all">{up.error}</p>
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}

          <div className="w-2.5 h-2.5 rounded-full bg-emerald-500 shadow-[0_0_10px_rgba(16,185,129,0.6)] animate-pulse" title="Connected" />
        </div>
      </header>

      <main className="flex-1 overflow-y-auto pb-24 relative">
        <div className={tab === 'library' ? '' : 'hidden'}>
          <Library 
            onPlay={() => setTab('player')} 
            uploads={uploads} 
            uploadFiles={uploadFiles}
            uploadSubtitle={uploadSubtitle}
          />
        </div>
        <div className={tab === 'downloads' ? '' : 'hidden'}>
          <Downloads />
        </div>
        <div className={tab === 'stream' ? '' : 'hidden'}>
          <Stream onPlay={() => setTab('player')} />
        </div>
        <div className={tab === 'player' ? '' : 'hidden'}>
          <Player active={tab === 'player'} />
        </div>
      </main>

      <nav className="fixed bottom-0 inset-x-0 grid grid-cols-4 border-t border-zinc-900/60 bg-zinc-950/85 backdrop-blur-lg pb-safe shadow-[0_-5px_20px_rgba(0,0,0,0.4)] z-10">
        {TABS.map((t) => {
          const active = tab === t.id
          return (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={`py-3 flex flex-col items-center gap-1 transition-all duration-300 ${
                active 
                  ? 'text-sky-400 scale-105 drop-shadow-[0_0_8px_rgba(56,189,248,0.2)]' 
                  : 'text-zinc-500 hover:text-zinc-300'
              }`}
            >
              <TabIcon
                id={t.id}
                className={`w-5 h-5 transition-transform duration-300 ${active ? 'scale-110' : 'opacity-80'}`}
              />
              <span className={`text-[10px] tracking-widest font-semibold transition-all ${active ? 'font-bold' : ''}`}>
                {t.label}
              </span>
            </button>
          )
        })}
      </nav>
    </div>
  )
}
