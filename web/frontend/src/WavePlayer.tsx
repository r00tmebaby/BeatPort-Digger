import { useEffect, useRef, useState } from 'react'
import WaveSurfer from 'wavesurfer.js'
import { camelotColor } from './api'
import type { Track } from './api'

function clock(seconds: number): string {
  if (!isFinite(seconds)) return '0:00'
  const m = Math.floor(seconds / 60)
  const s = Math.floor(seconds % 60)
    .toString()
    .padStart(2, '0')
  return `${m}:${s}`
}

export function WavePlayer({
  track,
  autoplay,
  onToggleAutoplay,
  onEnded,
  onClose,
}: {
  track: Track | null
  autoplay: boolean
  onToggleAutoplay: () => void
  onEnded: () => void
  onClose: () => void
}) {
  const containerRef = useRef<HTMLDivElement>(null)
  const wsRef = useRef<WaveSurfer | null>(null)
  const endedRef = useRef(onEnded)
  endedRef.current = onEnded

  const [playing, setPlaying] = useState(false)
  const [loading, setLoading] = useState(false)
  const [time, setTime] = useState(0)
  const [dur, setDur] = useState(0)

  // Create the wavesurfer instance once.
  useEffect(() => {
    if (!containerRef.current) return
    const ws = WaveSurfer.create({
      container: containerRef.current,
      height: 44,
      waveColor: '#b7d5c6',
      progressColor: '#0b8f57',
      cursorColor: '#04663f',
      barWidth: 2,
      barGap: 1,
      barRadius: 2,
    })
    ws.on('play', () => setPlaying(true))
    ws.on('pause', () => setPlaying(false))
    ws.on('ready', () => {
      setLoading(false)
      setDur(ws.getDuration())
      ws.play().catch(() => {})
    })
    ws.on('timeupdate', (t: number) => setTime(t))
    ws.on('finish', () => {
      setPlaying(false)
      endedRef.current()
    })
    wsRef.current = ws
    return () => ws.destroy()
  }, [])

  // Load whenever the track changes.
  useEffect(() => {
    const ws = wsRef.current
    if (!ws || !track) return
    setLoading(true)
    setTime(0)
    setDur(0)
    ws.load(`/api/preview/${track.id}`).catch(() => setLoading(false))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [track?.id])

  return (
    <footer className={track ? 'player active' : 'player'}>
      <div className="player-row">
        <button
          className="pp"
          onClick={() => wsRef.current?.playPause()}
          disabled={loading}
          title={playing ? 'Pause' : 'Play'}
        >
          {loading ? '…' : playing ? '❚❚' : '▶'}
        </button>
        <div className="wave-wrap">
          <div className="now-title">
            {track ? (
              <>
                {track.key && (
                  <span
                    className="key sm"
                    style={(() => {
                      const c = camelotColor(track.key)
                      return c ? { background: c.bg, color: c.fg } : undefined
                    })()}
                  >
                    {track.key}
                  </span>
                )}
                <span className="t">{track.title}</span>
                <span className="a">{track.artists}</span>
              </>
            ) : (
              'Nothing playing'
            )}
          </div>
          <div ref={containerRef} className="wave" />
        </div>
        <div className="clock">
          {clock(time)} / {clock(dur)}
        </div>
        <button
          className={autoplay ? 'auto on' : 'auto'}
          onClick={onToggleAutoplay}
          title={autoplay ? 'Autoplay on' : 'Autoplay off'}
        >
          ⏭
        </button>
        <button className="close" onClick={onClose} title="Stop">
          ✕
        </button>
      </div>
    </footer>
  )
}
