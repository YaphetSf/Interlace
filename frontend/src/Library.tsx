import React, { useEffect, useState, useRef } from 'react'
import { api } from './api'
import { VideoItem, DiskInfo, UploadTask } from './types/api'

const fmtSize = (b: number): string => (b > 1e9 ? (b / 1e9).toFixed(2) + ' GB' : (b / 1e6).toFixed(0) + ' MB')

interface VideoThumbnailProps {
  thumbnail: string;
  ext: string;
}

function VideoThumbnail({ thumbnail, ext }: VideoThumbnailProps) {
  const [failed, setFailed] = useState(false)

  if (failed) {
    return (
      <div className="w-full h-full bg-gradient-to-br from-zinc-900 to-zinc-950 border border-zinc-900/60 rounded-xl flex flex-col items-center justify-center text-zinc-600 relative shadow-inner overflow-hidden select-none">
        <div className="absolute inset-0 bg-[radial-gradient(circle_at_30%_20%,rgba(14,165,233,0.06),transparent)]" />
        <svg className="w-8 h-8 text-zinc-700 drop-shadow-[0_2px_8px_rgba(0,0,0,0.4)]" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 10.5l4.72-4.72a.75.75 0 011.28.53v11.38a.75.75 0 01-1.28.53l-4.72-4.72M4.5 18.75h9a2.25 2.25 0 002.25-2.25v-9a2.25 2.25 0 00-2.25-2.25h-9A2.25 2.25 0 002.25 7.5v9a2.25 2.25 0 002.25 2.25z" />
        </svg>
        <span className="text-[8px] font-bold tracking-widest text-zinc-550 uppercase mt-1.5 bg-zinc-950/40 px-1.5 py-0.5 rounded border border-zinc-900">{ext.substring(1)}</span>
      </div>
    )
  }

  return (
    <div className="w-full h-full rounded-xl overflow-hidden bg-zinc-950 relative border border-zinc-900/60 shadow-inner group/thumb">
      <img
        src={thumbnail}
        alt=""
        loading="lazy"
        onError={() => setFailed(true)}
        className="w-full h-full object-cover transition-transform duration-500 group-hover/thumb:scale-105"
      />
    </div>
  )
}

interface LibraryProps {
  onPlay: () => void;
  uploads: UploadTask[];
  uploadFiles: (filesList: File[] | FileList, currentPath: string) => void;
  uploadSubtitle: (videoPath: string, file: File, videoName: string) => void;
}

export default function Library({ onPlay, uploads, uploadFiles, uploadSubtitle }: LibraryProps) {
  const [items, setItems] = useState<VideoItem[]>([])
  const [currentPath, setCurrentPath] = useState<string>('')
  const [disk, setDisk] = useState<DiskInfo | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [loading, setLoading] = useState<boolean>(true)
  const [playing, setPlaying] = useState<string | null>(null)
  const [toDelete, setToDelete] = useState<VideoItem | null>(null)

  // Upload States
  const [dragging, setDragging] = useState<boolean>(false)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const folderInputRef = useRef<HTMLInputElement>(null)
  
  // Subtitle Upload States
  const subInputRef = useRef<HTMLInputElement>(null)
  const [activeVideoForSub, setActiveVideoForSub] = useState<VideoItem | null>(null)

  const load = (path: string = currentPath) => {
    setLoading(true)
    api
      .library(path)
      .then((d) => {
        setItems(d.items || [])
        setDisk(d.disk || null)
        setErr(null)
      })
      .catch((e: Error) => setErr(e.message))
      .finally(() => setLoading(false))
  }

  const [searchQuery, setSearchQuery] = useState<string>('')

  useEffect(() => {
    load(currentPath)
    setSearchQuery('')
  }, [currentPath])

  // Reload directory listing only when the count of successfully completed uploads increases
  const lastDoneCountRef = useRef<number>(0)
  useEffect(() => {
    const doneCount = uploads.filter((up) => up.status === 'done').length
    if (doneCount > lastDoneCountRef.current) {
      load(currentPath)
    }
    lastDoneCountRef.current = doneCount
  }, [uploads, currentPath])

  const play = async (item: VideoItem) => {
    setPlaying(item.path)
    try {
      await api.play(item.path)
      onPlay()
    } catch (e: any) {
      alert('Failed to play: ' + e.message)
    } finally {
      setPlaying(null)
    }
  }

  // Deletion Handlers
  const confirmDelete = (item: VideoItem) => {
    setToDelete(item)
  }

  const handleDelete = async () => {
    if (!toDelete) return
    try {
      await api.removeFile(toDelete.path)
      setToDelete(null)
      load()
    } catch (e: any) {
      alert('Failed to delete: ' + e.message)
    }
  }

  // Window-level Drag & Drop Handlers to allow dropping anywhere
  const dragCounter = useRef<number>(0)

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    if (e.target.files && e.target.files.length > 0) {
      uploadFiles(e.target.files, currentPath)
    }
  }

  useEffect(() => {
    const handleWindowDragEnter = (e: DragEvent) => {
      e.preventDefault()
      dragCounter.current++
      if (dragCounter.current === 1) {
        setDragging(true)
      }
    }

    const handleWindowDragLeave = (e: DragEvent) => {
      e.preventDefault()
      dragCounter.current--
      if (dragCounter.current === 0) {
        setDragging(false)
      }
    }

    const handleWindowDragOver = (e: DragEvent) => {
      e.preventDefault()
    }

    const handleWindowDrop = async (e: DragEvent) => {
      e.preventDefault()
      setDragging(false)
      dragCounter.current = 0
      
      const items = e.dataTransfer?.items
      if (items && items.length > 0) {
        const fileList: File[] = []
        
        const traverse = async (item: any, path = "") => {
          if (item.isFile) {
            const file = await new Promise<File>((resolve, reject) => {
              item.file(resolve, reject)
            })
            Object.defineProperty(file, 'webkitRelativePath', {
              value: path ? `${path}/${file.name}` : file.name,
              writable: true,
              configurable: true,
              enumerable: true
            })
            fileList.push(file)
          } else if (item.isDirectory) {
            const dirReader = item.createReader()
            const entries = await new Promise<any[]>((resolve) => {
              dirReader.readEntries(resolve)
            })
            for (const entry of entries) {
              await traverse(entry, path ? `${path}/${item.name}` : item.name)
            }
          }
        }
        
        const promises: Promise<void>[] = []
        for (let i = 0; i < items.length; i++) {
          const entry = items[i].webkitGetAsEntry()
          if (entry) {
            promises.push(traverse(entry))
          }
        }
        
        await Promise.all(promises)
        if (fileList.length > 0) {
          uploadFiles(fileList, currentPath)
        }
      } else if (e.dataTransfer?.files && e.dataTransfer.files.length > 0) {
        uploadFiles(Array.from(e.dataTransfer.files), currentPath)
      }
    }

    window.addEventListener('dragenter', handleWindowDragEnter)
    window.addEventListener('dragleave', handleWindowDragLeave)
    window.addEventListener('dragover', handleWindowDragOver)
    window.addEventListener('drop', handleWindowDrop)

    return () => {
      window.removeEventListener('dragenter', handleWindowDragEnter)
      window.removeEventListener('dragleave', handleWindowDragLeave)
      window.removeEventListener('dragover', handleWindowDragOver)
      window.removeEventListener('drop', handleWindowDrop)
    }
  }, [currentPath, uploadFiles])

  // Subtitle Upload Handlers
  const triggerSubtitleUpload = (item: VideoItem) => {
    setActiveVideoForSub(item)
    subInputRef.current?.click()
  }

  const handleSubtitleSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    if (e.target.files && e.target.files.length > 0 && activeVideoForSub) {
      uploadSubtitle(activeVideoForSub.path, e.target.files[0], activeVideoForSub.name)
    }
    e.target.value = ''
  }

  return (
    <div className="p-4 md:p-6 w-full max-w-7xl mx-auto space-y-5">
      <input
        type="file"
        ref={subInputRef}
        onChange={handleSubtitleSelect}
        className="hidden"
        accept=".srt,.ass,.vtt"
      />

      {/* Global Window Drag & Drop Overlay */}
      {dragging && (
        <div className="fixed inset-0 bg-zinc-950/85 backdrop-blur-md z-50 flex flex-col items-center justify-center p-6 transition-all duration-300">
          <div className="max-w-md w-full border-2 border-dashed border-sky-500/50 bg-zinc-900/30 rounded-3xl p-10 flex flex-col items-center text-center space-y-5 animate-scale-up shadow-2xl shadow-sky-500/5">
            <div className="w-20 h-20 rounded-full bg-sky-500/10 border border-sky-500/20 text-sky-400 flex items-center justify-center shadow-[0_0_30px_rgba(14,165,233,0.15)] animate-pulse">
              <svg className="w-10 h-10" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 16.5V9.75m0 0l3 3m-3-3l-3 3M6.75 19.5a4.5 4.5 0 01-1.41-8.775 5.25 5.25 0 0110.233-2.33 3 3 0 013.758 3.848A3.752 3.752 0 0118 19.5H6.75z" />
              </svg>
            </div>
            <div className="space-y-2">
              <h3 className="text-xl font-bold text-zinc-100">Upload to Interlace</h3>
              <p className="text-sm text-zinc-300">
                Release to upload files or folders directly to:
              </p>
              <div className="inline-block bg-sky-500/10 border border-sky-500/20 rounded-lg px-3 py-1 text-xs text-sky-400 font-mono font-semibold max-w-xs truncate">
                /{currentPath || 'Downloads'}
              </div>
            </div>
            <p className="text-xs text-zinc-500">Supports recursive folder trees and bulk file selections</p>
          </div>
        </div>
      )}

      {/* Main Two-Column Grid on desktop */}
      <div className="grid grid-cols-1 lg:grid-cols-[1fr_290px] xl:grid-cols-[1fr_330px] gap-6 items-start">
        
        {/* Left Column: Film List / Navigation */}
        <div className="space-y-4">
          
          {/* Breadcrumbs Header */}
          <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 bg-zinc-900/25 border border-zinc-900/60 p-4.5 rounded-2xl backdrop-blur-sm shadow-sm">
            <div className="flex items-center gap-2 min-w-0">
              <div className="flex flex-wrap items-center gap-1 text-xs text-zinc-400 font-medium min-w-0">
                <button
                  onClick={() => setCurrentPath('')}
                  className="hover:text-sky-400 text-zinc-300 hover:scale-105 active:scale-95 transition-all flex items-center gap-1 font-bold cursor-pointer shrink-0"
                >
                  <svg className="w-4 h-4 text-sky-400 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 12l8.954-8.955c.44-.439 1.152-.439 1.591 0L21.75 12M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-4.875c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125V21h4.125c.621 0 1.125-.504 1.125-1.125V9.75M8.25 21h8.25" />
                  </svg>
                  <span>Library</span>
                </button>

                {currentPath ? (
                  currentPath.split('/').map((crumb, idx, arr) => {
                    const path = arr.slice(0, idx + 1).join('/')
                    const isLast = idx === arr.length - 1
                    return (
                      <React.Fragment key={path}>
                        <span className="text-zinc-650 font-medium select-none mx-0.5">/</span>
                        {isLast ? (
                          <span className="text-zinc-200 font-semibold truncate max-w-40 bg-zinc-800/40 px-2 py-0.5 rounded-md border border-zinc-800/60" title={crumb}>{crumb}</span>
                        ) : (
                          <button
                            onClick={() => setCurrentPath(path)}
                            className="hover:text-sky-400 hover:scale-102 transition-all truncate max-w-40 cursor-pointer text-zinc-400"
                            title={crumb}
                          >
                            {crumb}
                          </button>
                        )}
                      </React.Fragment>
                    )
                  })
                ) : (
                  <>
                    <span className="text-zinc-650 font-medium select-none mx-0.5">/</span>
                    <span className="text-zinc-200 font-semibold bg-zinc-800/40 px-2 py-0.5 rounded-md border border-zinc-800/60">Downloads</span>
                  </>
                )}
              </div>
            </div>

            <div className="flex items-center gap-3 shrink-0 self-end sm:self-auto">
              {/* Search Box */}
              <div className="relative">
                <svg className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3 h-3 text-zinc-500 pointer-events-none" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-4.35-4.35M17 11A6 6 0 1 1 5 11a6 6 0 0 1 12 0z" />
                </svg>
                <input
                  type="text"
                  value={searchQuery}
                  onChange={(e) => setSearchQuery(e.target.value)}
                  placeholder="Search..."
                  className="pl-7 pr-3 py-1.5 text-xs bg-zinc-950/60 border border-zinc-900 rounded-xl text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-sky-800 focus:ring-1 focus:ring-sky-800/40 transition-all w-36 sm:w-44"
                />
              </div>
              <span className="text-[10px] font-bold tracking-wider text-zinc-500 uppercase select-none bg-zinc-950/40 px-2 py-1 rounded-lg border border-zinc-900/65">
                {items.length} {items.length === 1 ? 'item' : 'items'}
              </span>
              <button
                onClick={() => load(currentPath)}
                className="text-xs font-bold text-sky-400 hover:text-sky-300 hover:scale-105 active:scale-95 transition-all cursor-pointer select-none flex items-center gap-1.5 bg-sky-950/20 border border-sky-900/30 px-3 py-1.5 rounded-xl shadow-sm hover:bg-sky-950/30 hover:border-sky-850"
              >
                <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0l3.181 3.183a8.25 8.25 0 0013.803-3.7M4.031 9.865a8.25 8.25 0 0113.803-3.7l3.181 3.182m0-4.991v4.99" />
                </svg>
                <span>Refresh</span>
              </button>
            </div>
          </div>

          {/* Directory Navigation Go Back (Top level subpath) */}
          {currentPath && (() => {
            const parts = currentPath.split('/')
            parts.pop()
            const parentName = parts.length === 0 ? 'Library' : parts[parts.length - 1]
            return (
              <button
                onClick={() => setCurrentPath(parts.join('/'))}
                className="w-full py-2.5 px-4 bg-zinc-900/15 border border-zinc-900/50 hover:bg-zinc-900/35 hover:border-zinc-800 rounded-2xl flex items-center gap-2 text-xs font-bold text-zinc-400 hover:text-sky-400 transition-all active:scale-[0.995] cursor-pointer shadow-sm select-none"
              >
                <svg className="w-4 h-4 text-zinc-550" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M10 19l-7-7m0 0l7-7m-7 7h18" />
                </svg>
                <span>← {parentName}</span>
              </button>
            )
          })()}

          {/* Scan Diagnostics / Status Warnings */}
          {err && (
            <div className="text-rose-455 text-xs break-all bg-rose-500/5 border border-rose-500/10 rounded-2xl p-4 leading-relaxed font-semibold">
              {err}
            </div>
          )}

          {loading && (
            <div className="flex flex-col items-center justify-center py-20 space-y-3 bg-zinc-900/10 border border-zinc-900/40 rounded-3xl backdrop-blur-sm">
              <div className="w-8 h-8 border-2 border-sky-500/20 border-t-sky-500 rounded-full animate-spin" />
              <div className="text-zinc-500 text-xs font-bold tracking-wider uppercase animate-pulse">Scanning Storage...</div>
            </div>
          )}

          {!loading && items.length === 0 && (
            <div className="flex flex-col items-center justify-center py-20 space-y-4 border border-zinc-900/60 rounded-3xl bg-zinc-900/10 backdrop-blur-sm">
              <div className="w-14 h-14 rounded-2xl bg-zinc-950 border border-zinc-900 flex items-center justify-center text-zinc-650 shadow-inner">
                <svg className="w-7 h-7" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M20.25 7.5l-.625 10.632a2.25 2.25 0 01-2.247 2.118H6.622a2.25 2.25 0 01-2.247-2.118L3.75 7.5m8.25-3v6.75m0 0l-3-3m3 3l3-3M3.375 7.5h17.25c.621 0 1.125-.504 1.125-1.125v-1.5c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 1.125v1.5c0 .621.504 1.125 1.125 1.125z" />
                </svg>
              </div>
              <div className="text-center space-y-1">
                <p className="text-sm font-semibold text-zinc-400">Empty Directory</p>
                <p className="text-xs text-zinc-500">Drag & drop video files or folders to populate this space</p>
              </div>
            </div>
          )}

          {/* Cards Grid */}
          {!loading && items.length > 0 && (() => {
            const filtered = searchQuery
              ? items.filter((it) => it.name.toLowerCase().includes(searchQuery.toLowerCase()))
              : items
            return (
              <>
                {filtered.length === 0 && (
                  <div className="flex flex-col items-center justify-center py-16 space-y-3 border border-zinc-900/50 rounded-3xl bg-zinc-900/10">
                    <svg className="w-6 h-6 text-zinc-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-4.35-4.35M17 11A6 6 0 1 1 5 11a6 6 0 0 1 12 0z" />
                    </svg>
                    <p className="text-xs text-zinc-500 font-semibold">No results for "{searchQuery}"</p>
                  </div>
                )}
                <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-2 xl:grid-cols-3 gap-4.5">
              {filtered.map((it) => {
                const isDir = it.type === 'directory'
                
                if (isDir) {
                  return (
                    <div
                      key={it.path}
                      onClick={() => setCurrentPath(it.rel)}
                      className="bg-zinc-900/30 border border-zinc-900/60 rounded-2xl p-4 flex flex-col justify-between h-[270px] hover:bg-sky-950/15 hover:border-sky-900/40 cursor-pointer hover:scale-[1.02] active:scale-[0.99] transition-all duration-300 shadow-sm group/item hover:shadow-lg hover:shadow-sky-500/5"
                    >
                      <div className="w-full h-32 rounded-xl bg-sky-950/20 border border-sky-900/20 flex items-center justify-center text-sky-400 shrink-0 shadow-inner group-hover/item:bg-sky-950/30 group-hover/item:border-sky-850 transition-colors">
                        <svg className="w-12 h-12" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                          <path strokeLinecap="round" strokeLinejoin="round" d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z" />
                        </svg>
                      </div>

                      <div className="min-w-0 flex-1 pt-3 flex flex-col justify-between">
                        <div className="min-w-0">
                          <div className="text-sm font-semibold text-zinc-200 group-hover/item:text-sky-400 transition-colors line-clamp-1 truncate" title={it.name}>
                            {it.name}
                          </div>
                          <div className="text-[10px] text-zinc-550 font-bold uppercase mt-0.5 tracking-wider">Folder</div>
                        </div>
                        
                        <div className="flex justify-between items-center text-[10px] text-sky-400/80 font-bold group-hover/item:text-sky-400 transition-colors pt-2 border-t border-sky-950/30">
                          <button
                            onClick={(e) => { e.stopPropagation(); confirmDelete(it) }}
                            className="p-1 -ml-1 rounded-md text-zinc-500 hover:text-rose-450 hover:bg-rose-950/20 active:scale-90 transition-all cursor-pointer"
                            title="Delete Folder"
                          >
                            <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                              <path strokeLinecap="round" strokeLinejoin="round" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                            </svg>
                          </button>
                          <span>Open Folder ➔</span>
                        </div>
                      </div>
                    </div>
                  )
                }

                const fileExt = it.name.substring(it.name.lastIndexOf('.'))

                return (
                  <div
                    key={it.path}
                    className="bg-zinc-900/30 border border-zinc-900/60 rounded-2xl p-4 flex flex-col justify-between h-[270px] hover:bg-zinc-900/60 hover:border-zinc-850 hover:scale-[1.02] transition-all duration-300 shadow-sm group/item hover:shadow-lg hover:shadow-sky-500/2"
                  >
                    {/* Dynamic video thumbnail player */}
                    <div className="w-full h-32 shrink-0">
                      <VideoThumbnail thumbnail={it.thumbnail || ''} ext={fileExt} />
                    </div>

                    <div className="min-w-0 flex-1 pt-3 flex flex-col justify-between">
                      <div className="min-w-0">
                        <div className="text-sm font-semibold text-zinc-200 group-hover/item:text-sky-400 transition-colors line-clamp-1 truncate" title={it.name}>
                          {it.name}
                        </div>
                        <div className="text-[10px] text-zinc-500 mt-0.5 truncate">
                          {fmtSize(it.size || 0)}
                          {it.rel !== it.name ? ' · ' + it.rel.substring(0, it.rel.lastIndexOf('/')) : ''}
                        </div>
                      </div>

                      <div className="flex items-center justify-between gap-2 pt-2 border-t border-zinc-900/35">
                        <button
                          onClick={() => play(it)}
                          disabled={playing === it.path}
                          className="flex-1 py-1.5 px-3 rounded-lg bg-sky-950/45 hover:bg-sky-500 hover:text-zinc-950 border border-sky-900/40 hover:border-sky-500 text-sky-400 text-[10px] font-bold transition-all active:scale-95 shadow-sm flex items-center justify-center gap-1 disabled:opacity-50 cursor-pointer"
                        >
                          {playing === it.path ? (
                            'Loading...'
                          ) : (
                            <>
                              <svg className="w-3 h-3 fill-current shrink-0" viewBox="0 0 24 24">
                                <path d="M8 5v14l11-7z" />
                              </svg>
                              <span>Play</span>
                            </>
                          )}
                        </button>

                        <div className="flex gap-1.5 shrink-0">
                          <button
                            onClick={() => triggerSubtitleUpload(it)}
                            className="p-1.5 rounded-lg bg-zinc-950 border border-zinc-900 text-zinc-400 hover:text-sky-400 hover:bg-sky-950/20 hover:border-sky-900/30 active:scale-90 transition-all cursor-pointer flex items-center justify-center shadow-inner"
                            title="Upload Subtitles"
                          >
                            <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                              <path strokeLinecap="round" strokeLinejoin="round" d="M7 8h10M7 12h4m1 8l-4-4H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-3l-4 4z" />
                            </svg>
                          </button>
                          
                          <button
                            onClick={() => confirmDelete(it)}
                            className="p-1.5 rounded-lg bg-zinc-950 border border-zinc-900 text-zinc-405 hover:text-rose-450 hover:bg-rose-950/20 hover:border-rose-900/30 active:scale-90 transition-all cursor-pointer flex items-center justify-center shadow-inner"
                            title="Delete Video"
                          >
                            <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                              <path strokeLinecap="round" strokeLinejoin="round" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                            </svg>
                          </button>
                        </div>
                      </div>
                    </div>
                  </div>
                )
              })}
                </div>
              </>
            )
          })()}
        </div>

        {/* Right Column: Sidebar Widgets */}
        <div className="space-y-4">
          
          {/* Disk Space Card */}
          {disk && (
            <div className="bg-zinc-900/40 border border-zinc-900/60 rounded-2xl p-4.5 backdrop-blur-sm space-y-3.5 shadow-sm">
              <div className="flex justify-between items-center text-xs text-zinc-400">
                <span className="font-semibold flex items-center gap-1.5 text-zinc-300">
                  <svg className="w-4 h-4 shrink-0 text-zinc-405" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M20.25 6.375c0 2.278-3.694 4.125-8.25 4.125S3.75 8.653 3.75 6.375m16.5 0c0-2.278-3.694-4.125-8.25-4.125S3.75 4.097 3.75 6.375m16.5 0v11.25c0 2.278-3.694 4.125-8.25 4.125s-8.25-1.847-8.25-4.125V6.375m16.5 0v3.75m-16.5-3.75v3.75m16.5 0v3.75C20.25 16.153 16.556 18 12 18s-8.25-1.847-8.25-4.125v-3.75m16.5 0v3.75m-16.5-3.75v3.75" />
                  </svg>
                  Disk Space
                </span>
                <span className="text-[10px] font-bold text-zinc-550 uppercase tracking-widest bg-zinc-950/40 border border-zinc-900/70 px-1.5 py-0.5 rounded">
                  {disk.percent}% Used
                </span>
              </div>
              
              <div className="space-y-1.5">
                <div className="h-2 w-full bg-zinc-800 rounded-full overflow-hidden shadow-inner">
                  <div
                    className={`h-full rounded-full transition-all duration-500 ease-out bg-gradient-to-r ${
                      disk.percent > 90
                        ? 'from-rose-500 to-red-500'
                        : disk.percent > 75
                        ? 'from-amber-500 to-orange-500'
                        : 'from-sky-500 to-indigo-500 shadow-[0_0_8px_rgba(14,165,233,0.3)]'
                    }`}
                    style={{ width: `${disk.percent}%` }}
                  />
                </div>
                <div className="flex justify-between text-[10px] text-zinc-550 font-semibold tabular-nums">
                  <span>Used: {fmtSize(disk.used)}</span>
                  <span>Free: {fmtSize(disk.free)}</span>
                </div>
              </div>
            </div>
          )}

          {/* Upload Console Card */}
          <div className="bg-zinc-900/40 border border-zinc-900/60 rounded-2xl p-4.5 backdrop-blur-sm space-y-4 shadow-sm">
            <div className="space-y-1">
              <h3 className="text-xs font-bold tracking-wider text-zinc-300 uppercase flex items-center gap-1.5">
                <svg className="w-4 h-4 text-sky-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M12 16.5V9.75m0 0l3 3m-3-3l-3 3M6.75 19.5a4.5 4.5 0 01-1.41-8.775 5.25 5.25 0 0110.233-2.33 3 3 0 013.758 3.848A3.752 3.752 0 0118 19.5H6.75z" />
                </svg>
                Upload Console
              </h3>
              <p className="text-[10px] text-zinc-500 leading-relaxed">
                Drag files or folders **anywhere** over this screen to drop-upload, or trigger native pickers below:
              </p>
            </div>

            <div className="grid grid-cols-2 gap-2">
              <button
                onClick={() => fileInputRef.current?.click()}
                className="py-2.5 rounded-xl bg-zinc-950 hover:bg-zinc-900 border border-zinc-900 hover:border-zinc-800 text-zinc-300 hover:text-sky-400 text-[10px] font-bold transition-all active:scale-95 cursor-pointer shadow-sm flex items-center justify-center gap-1"
              >
                <svg className="w-3.5 h-3.5 text-zinc-500" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m3.75 9v6m3-3H9m1.5-12H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 00-9-9z" />
                </svg>
                Files
              </button>
              <button
                onClick={() => folderInputRef.current?.click()}
                className="py-2.5 rounded-xl bg-zinc-950 hover:bg-zinc-900 border border-zinc-900 hover:border-zinc-800 text-zinc-300 hover:text-sky-400 text-[10px] font-bold transition-all active:scale-95 cursor-pointer shadow-sm flex items-center justify-center gap-1"
              >
                <svg className="w-3.5 h-3.5 text-zinc-500" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M12 10.5v6m3-3H9m4.06-7.19l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z" />
                </svg>
                Folder
              </button>
            </div>

            <input
              type="file"
              ref={fileInputRef}
              onChange={handleFileSelect}
              multiple
              className="hidden"
              accept="video/*"
            />
            <input
              type="file"
              ref={folderInputRef}
              onChange={handleFileSelect}
              multiple
              {...{ webkitdirectory: "true", directory: "true" }}
              className="hidden"
            />
          </div>
        </div>

      </div>

      {/* Deletion Confirmation Modal */}
      {toDelete && (
        <div className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center p-4 z-50 animate-fade-in">
          <div className="bg-zinc-950 border border-zinc-900 rounded-2xl p-6 max-w-sm w-full space-y-4 shadow-2xl animate-scale-up">
            <div className="text-center space-y-2">
              <div className="w-12 h-12 rounded-full bg-rose-500/10 text-rose-450 flex items-center justify-center mx-auto border border-rose-500/20 shadow-[0_0_15px_rgba(244,63,94,0.15)]">
                <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                </svg>
              </div>
              <h3 className="text-base font-bold text-zinc-100">Confirm Delete {toDelete.type === 'directory' ? 'Folder' : 'Video'}</h3>
              <p className="text-xs text-zinc-400 break-all px-2 leading-relaxed">
                Are you sure you want to delete <span className="font-semibold text-zinc-200">{toDelete.name}</span>?{' '}
                {toDelete.type === 'directory'
                  ? 'This will permanently remove the entire folder and everything inside it'
                  : 'This action will permanently remove the file from the disk'}
                {' '}and cannot be undone.
              </p>
            </div>
            <div className="grid grid-cols-2 gap-3 pt-2">
              <button
                onClick={() => setToDelete(null)}
                className="py-2.5 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-300 text-xs font-semibold tracking-wider transition-colors cursor-pointer"
              >
                Cancel
              </button>
              <button
                onClick={handleDelete}
                className="py-2.5 rounded-xl bg-rose-600 hover:bg-rose-500 text-white text-xs font-bold tracking-wider transition-all active:scale-95 shadow-[0_4px_15px_rgba(225,29,72,0.3)] cursor-pointer"
              >
                Confirm Delete
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
