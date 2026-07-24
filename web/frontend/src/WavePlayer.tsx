import { useEffect, useRef, useState } from 'react'
import WaveSurfer from 'wavesurfer.js'
import { Box, Chip, CircularProgress, IconButton, Paper, Typography } from '@mui/material'
import PlayArrowIcon from '@mui/icons-material/PlayArrow'
import PauseIcon from '@mui/icons-material/Pause'
import SkipNextIcon from '@mui/icons-material/SkipNext'
import CloseIcon from '@mui/icons-material/Close'
import { camelotColor } from './api'
import type { Track } from './api'

function clock(seconds: number): string {
  if (!isFinite(seconds)) return '0:00'
  const m = Math.floor(seconds / 60)
  const s = Math.floor(seconds % 60).toString().padStart(2, '0')
  return `${m}:${s}`
}

export function WavePlayer({
  track,
  autoplay,
  onToggleAutoplay,
  onEnded,
  onClose,
  onStatus,
}: {
  track: Track | null
  autoplay: boolean
  onToggleAutoplay: () => void
  onEnded: () => void
  onClose: () => void
  onStatus?: (loading: boolean, playing: boolean) => void
}) {
  const containerRef = useRef<HTMLDivElement>(null)
  const wsRef = useRef<WaveSurfer | null>(null)
  const endedRef = useRef(onEnded)
  endedRef.current = onEnded

  const [playing, setPlaying] = useState(false)
  const [loading, setLoading] = useState(false)
  const [time, setTime] = useState(0)
  const [dur, setDur] = useState(0)

  const statusRef = useRef(onStatus)
  statusRef.current = onStatus
  useEffect(() => {
    statusRef.current?.(loading, playing)
  }, [loading, playing])

  useEffect(() => {
    if (!containerRef.current) return
    const ws = WaveSurfer.create({
      container: containerRef.current,
      height: 40,
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

  useEffect(() => {
    const ws = wsRef.current
    if (!ws || !track) return
    setLoading(true)
    setTime(0)
    setDur(0)
    ws.load(`/api/preview/${track.id}`).catch(() => setLoading(false))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [track?.id])

  const keyColor = camelotColor(track?.key ?? null)

  return (
    <Paper
      square
      elevation={4}
      sx={{
        position: 'fixed',
        left: 0,
        right: 0,
        bottom: 0,
        display: track ? 'block' : 'none',
        px: 1.5,
        py: 1,
        pb: 'calc(8px + env(safe-area-inset-bottom))',
      }}
    >
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
        <IconButton color="primary" disabled={loading} onClick={() => wsRef.current?.playPause()}>
          {loading ? <CircularProgress size={22} /> : playing ? <PauseIcon /> : <PlayArrowIcon />}
        </IconButton>
        <Box sx={{ flex: 1, minWidth: 0 }}>
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 0.25 }}>
            {track?.key && keyColor && (
              <Chip
                size="small"
                label={track.key}
                sx={{ bgcolor: keyColor.bg, color: keyColor.fg, fontWeight: 700, height: 20 }}
              />
            )}
            <Typography variant="body2" noWrap sx={{ fontWeight: 600 }}>
              {track?.title}
            </Typography>
            <Typography variant="caption" color="text.secondary" noWrap>
              {track?.artists}
            </Typography>
          </Box>
          <Box sx={{ position: 'relative' }}>
            <div ref={containerRef} style={{ cursor: 'pointer' }} />
            {loading && (
              <Box sx={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', gap: 1 }}>
                <CircularProgress size={14} />
                <Typography variant="caption" color="text.secondary">Loading preview…</Typography>
              </Box>
            )}
          </Box>
        </Box>
        <Typography variant="caption" color="text.secondary" sx={{ fontVariantNumeric: 'tabular-nums' }}>
          {clock(time)} / {clock(dur)}
        </Typography>
        <IconButton
          color={autoplay ? 'primary' : 'default'}
          onClick={onToggleAutoplay}
          title={autoplay ? 'Autoplay on' : 'Autoplay off'}
        >
          <SkipNextIcon />
        </IconButton>
        <IconButton onClick={onClose} title="Stop">
          <CloseIcon />
        </IconButton>
      </Box>
    </Paper>
  )
}
