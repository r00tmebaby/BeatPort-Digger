import { useEffect, useMemo, useState } from 'react'
import {
  Alert,
  AppBar,
  Box,
  Button,
  Chip,
  CircularProgress,
  Collapse,
  Container,
  IconButton,
  MenuItem,
  Pagination,
  Paper,
  Tab,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TableSortLabel,
  Tabs,
  TextField,
  Toolbar,
  Typography,
} from '@mui/material'
import PlayArrowIcon from '@mui/icons-material/PlayArrow'
import PauseIcon from '@mui/icons-material/Pause'
import DownloadIcon from '@mui/icons-material/Download'
import FilterListIcon from '@mui/icons-material/FilterList'
import GraphicEqIcon from '@mui/icons-material/GraphicEq'
import { api, camelotColor, downloadTrack, harmonicNeighbours } from './api'
import type { Genre, SearchResponse, Track } from './api'
import { sortTracks } from './sort'
import type { Order, SortKey } from './sort'
import { WavePlayer } from './WavePlayer'

const SORTS: [string, string][] = [
  ['-publish_date', 'Newest'],
  ['publish_date', 'Oldest'],
  ['-plays', 'Most played'],
  ['-downloads', 'Most downloaded'],
  ['name', 'Title'],
  ['bpm', 'BPM'],
]

// A useState that mirrors to localStorage, so search state survives a refresh.
function usePersisted<T>(key: string, initial: T): [T, React.Dispatch<React.SetStateAction<T>>] {
  const [value, setValue] = useState<T>(() => {
    try {
      const raw = localStorage.getItem(key)
      return raw !== null ? (JSON.parse(raw) as T) : initial
    } catch {
      return initial
    }
  })
  useEffect(() => {
    try {
      localStorage.setItem(key, JSON.stringify(value))
    } catch {
      // storage full or unavailable; state still works for the session.
    }
  }, [key, value])
  return [value, setValue]
}

function Logo() {
  return (
    <GraphicEqIcon sx={{ color: 'primary.main', mr: 1 }} />
  )
}

function Login({ onDone }: { onDone: () => void }) {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await api('/api/login', { method: 'POST', body: JSON.stringify({ username, password }) })
      onDone()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Sign-in failed')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Container maxWidth="xs" sx={{ mt: '14vh' }}>
      <Box component="form" onSubmit={submit} sx={{ display: 'flex', flexDirection: 'column', gap: 2, textAlign: 'center' }}>
        <Box sx={{ display: 'flex', justifyContent: 'center', alignItems: 'center' }}>
          <Logo />
          <Typography variant="h5" sx={{ fontWeight: 700 }}>BeatPort Digger</Typography>
        </Box>
        <Typography color="text.secondary">Sign in with your Beatport account</Typography>
        <TextField label="Username" value={username} onChange={(e) => setUsername(e.target.value)} autoFocus />
        <TextField label="Password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
        <Button type="submit" variant="contained" size="large" disabled={busy || !username || !password}>
          {busy ? 'Signing in…' : 'Sign in'}
        </Button>
        {error && <Alert severity="error">{error}</Alert>}
        <Typography variant="caption" color="text.secondary">
          Your password is used once to get a token and is not stored.
        </Typography>
      </Box>
    </Container>
  )
}

function Wheel({ selected, onPick }: { selected: string; onPick: (code: string) => void }) {
  const neighbours = harmonicNeighbours(selected)
  const codes: string[] = []
  for (let n = 1; n <= 12; n++) for (const l of ['A', 'B']) codes.push(`${n}${l}`)
  return (
    <Box sx={{ display: 'grid', gridTemplateColumns: 'repeat(8, 1fr)', gap: 0.75 }}>
      {codes.map((c) => {
        const active = c === selected || neighbours.includes(c)
        const cc = camelotColor(c)!
        return (
          <Box
            key={c}
            component="button"
            onClick={() => onPick(c)}
            sx={{
              border: 0,
              borderRadius: 1,
              py: 1,
              cursor: 'pointer',
              fontWeight: 700,
              fontSize: 13,
              bgcolor: cc.bg,
              color: cc.fg,
              opacity: active ? 1 : 0.4,
              boxShadow: c === selected ? 'inset 0 0 0 2.5px #11201a' : 'none',
            }}
          >
            {c}
          </Box>
        )
      })}
    </Box>
  )
}

function GenreSelect({ value, onChange, genres }: { value: string; onChange: (v: string) => void; genres: Genre[] }) {
  return (
    <TextField select size="small" label="Genre" value={value} onChange={(e) => onChange(e.target.value)} sx={{ minWidth: 140 }}>
      <MenuItem value="">Any genre</MenuItem>
      {genres.map((g) => (
        <MenuItem key={g.id} value={String(g.id)}>{g.name}</MenuItem>
      ))}
    </TextField>
  )
}

type Column = { key: SortKey; label: string; align?: 'right' | 'center'; sortable?: boolean }
const COLUMNS: Column[] = [
  { key: 'index', label: '#', sortable: false },
  { key: 'title', label: 'Title', sortable: true },
  { key: 'artists', label: 'Artists', sortable: true },
  { key: 'label', label: 'Label', sortable: true },
  { key: 'genre', label: 'Genre', sortable: true },
  { key: 'bpm', label: 'BPM', align: 'center', sortable: true },
  { key: 'key', label: 'Key', align: 'center', sortable: true },
  { key: 'length', label: 'Len', align: 'center', sortable: true },
]

export default function App() {
  const [authed, setAuthed] = useState<boolean | null>(null)
  const [tab, setTab] = usePersisted('bpd_tab', 0)
  const [genres, setGenres] = useState<Genre[]>([])

  const [title, setTitle] = usePersisted('bpd_title', '')
  const [artist, setArtist] = usePersisted('bpd_artist', '')
  const [label, setLabel] = usePersisted('bpd_label', '')
  const [genre, setGenre] = usePersisted('bpd_genre', '')
  const [bpmLow, setBpmLow] = usePersisted('bpd_bpmLow', '')
  const [bpmHigh, setBpmHigh] = usePersisted('bpd_bpmHigh', '')
  const [sort, setSort] = usePersisted('bpd_sort', '-publish_date')
  const [showFilters, setShowFilters] = useState(false)

  const [selKey, setSelKey] = usePersisted('bpd_selKey', '8A')
  const [hGenre, setHGenre] = usePersisted('bpd_hGenre', '')
  const [hBpmLow, setHBpmLow] = usePersisted('bpd_hBpmLow', '')
  const [hBpmHigh, setHBpmHigh] = usePersisted('bpd_hBpmHigh', '')

  const [searchResults, setSearchResults] = usePersisted<Track[]>('bpd_searchResults', [])
  const [harmonicResults, setHarmonicResults] = usePersisted<Track[]>('bpd_harmonicResults', [])
  const [count, setCount] = usePersisted('bpd_count', 0)
  const [page, setPage] = usePersisted('bpd_page', 1)
  const [busy, setBusy] = useState(false)
  const [pStatus, setPStatus] = useState({ loading: false, playing: false })
  const [error, setError] = useState<string | null>(null)
  const [current, setCurrent] = useState<Track | null>(null)
  const [autoplay, setAutoplay] = useState(true)
  const [downloading, setDownloading] = useState<number | null>(null)
  const [downloads, setDownloads] = useState<Track[]>(() => {
    try {
      return JSON.parse(localStorage.getItem('bpd_downloads') || '[]') as Track[]
    } catch {
      return []
    }
  })

  const [sortKey, setSortKey] = useState<SortKey>('index')
  const [order, setOrder] = useState<Order>('asc')

  useEffect(() => {
    api<{ authenticated: boolean }>('/api/status').then((s) => setAuthed(s.authenticated)).catch(() => setAuthed(false))
  }, [])
  useEffect(() => {
    if (!authed) return
    api<{ genres: Genre[] }>('/api/genres').then((g) => setGenres(g.genres)).catch(() => {})
  }, [authed])
  useEffect(() => {
    localStorage.setItem('bpd_downloads', JSON.stringify(downloads))
  }, [downloads])

  const rows = useMemo(
    () =>
      sortTracks(
        tab === 2 ? downloads : tab === 1 ? harmonicResults : searchResults,
        sortKey,
        order,
      ),
    [tab, downloads, harmonicResults, searchResults, sortKey, order],
  )

  function handleSort(key: SortKey) {
    if (key === sortKey) setOrder((o) => (o === 'asc' ? 'desc' : 'asc'))
    else {
      setSortKey(key)
      setOrder('asc')
    }
  }

  async function runSearch(nextPage = 1, overrides: Record<string, string> = {}) {
    const f = { title, artist, label, genre, bpmLow, bpmHigh, sort, ...overrides }
    setBusy(true)
    setError(null)
    try {
      const p = new URLSearchParams()
      if (f.title.trim()) p.set('title', f.title.trim())
      if (f.artist.trim()) p.set('artist', f.artist.trim())
      if (f.label.trim()) p.set('label', f.label.trim())
      if (f.genre) p.set('genre', f.genre)
      if (f.bpmLow.trim()) p.set('bpmLow', f.bpmLow.trim())
      if (f.bpmHigh.trim()) p.set('bpmHigh', f.bpmHigh.trim())
      p.set('sort', f.sort)
      p.set('page', String(nextPage))
      const data = await api<SearchResponse>(`/api/search?${p.toString()}`)
      setSearchResults(data.results)
      setCount(data.count)
      setPage(nextPage)
      setSortKey('index')
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Search failed')
    } finally {
      setBusy(false)
    }
  }

  // The active search filters, shown as removable chips in one row like the app.
  const activeChips: { label: string; clear: () => void }[] = []
  if (tab === 0) {
    if (artist.trim()) activeChips.push({ label: `Artist: ${artist}`, clear: () => { setArtist(''); runSearch(1, { artist: '' }) } })
    if (label.trim()) activeChips.push({ label: `Label: ${label}`, clear: () => { setLabel(''); runSearch(1, { label: '' }) } })
    if (genre) {
      const name = genres.find((g) => String(g.id) === genre)?.name ?? genre
      activeChips.push({ label: `Genre: ${name}`, clear: () => { setGenre(''); runSearch(1, { genre: '' }) } })
    }
    if (bpmLow.trim() || bpmHigh.trim()) {
      activeChips.push({ label: `BPM ${bpmLow || '…'}-${bpmHigh || '…'}`, clear: () => { setBpmLow(''); setBpmHigh(''); runSearch(1, { bpmLow: '', bpmHigh: '' }) } })
    }
    if (sort !== '-publish_date') {
      const name = SORTS.find(([v]) => v === sort)?.[1] ?? sort
      activeChips.push({ label: `Sort: ${name}`, clear: () => { setSort('-publish_date'); runSearch(1, { sort: '-publish_date' }) } })
    }
  }

  const perPage = 60
  const totalPages = Math.ceil(Math.min(count, 10000) / perPage)

  async function runHarmonic() {
    setBusy(true)
    setError(null)
    try {
      const p = new URLSearchParams({ key: selKey })
      if (hGenre) p.set('genre', hGenre)
      if (hBpmLow.trim()) p.set('bpmLow', hBpmLow.trim())
      if (hBpmHigh.trim()) p.set('bpmHigh', hBpmHigh.trim())
      const data = await api<SearchResponse>(`/api/harmonic?${p.toString()}`)
      setHarmonicResults(data.results)
      setSortKey('index')
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Harmonic search failed')
    } finally {
      setBusy(false)
    }
  }

  function playNext() {
    if (!autoplay || !current) return
    const i = rows.findIndex((t) => t.id === current.id)
    if (i >= 0 && i + 1 < rows.length) setCurrent(rows[i + 1])
  }

  async function download(t: Track) {
    setDownloading(t.id)
    setError(null)
    try {
      await downloadTrack(t)
      setDownloads((d) => (d.some((x) => x.id === t.id) ? d : [t, ...d]))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Download failed')
    } finally {
      setDownloading(null)
    }
  }

  if (authed === null) {
    return <Box sx={{ display: 'flex', justifyContent: 'center', mt: 8 }}><CircularProgress /></Box>
  }
  if (!authed) return <Login onDone={() => setAuthed(true)} />

  return (
    <Box sx={{ height: '100vh', display: 'flex', flexDirection: 'column' }}>
      <AppBar position="static" color="default" elevation={1}>
        <Toolbar variant="dense">
          <Logo />
          <Typography variant="h6" sx={{ fontWeight: 700, mr: 3 }}>BeatPort Digger</Typography>
          <Tabs value={tab} onChange={(_, v) => setTab(v)}>
            <Tab label="Search" />
            <Tab label="Harmonic" />
            <Tab label={`Downloads${downloads.length ? ` (${downloads.length})` : ''}`} />
          </Tabs>
        </Toolbar>
      </AppBar>

      <Box sx={{ px: 2, pt: 2 }}>
        {tab === 0 ? (
          <Box component="form" onSubmit={(e) => { e.preventDefault(); runSearch(1) }}>
            <Box sx={{ display: 'flex', gap: 1 }}>
              <TextField fullWidth size="small" label="Search title" value={title} onChange={(e) => setTitle(e.target.value)} />
              <IconButton onClick={() => setShowFilters((s) => !s)} color={showFilters ? 'primary' : 'default'}>
                <FilterListIcon />
              </IconButton>
              <Button type="submit" variant="contained" disabled={busy}>Search</Button>
            </Box>
            <Collapse in={showFilters}>
              <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 1, mt: 1.5 }}>
                <TextField size="small" label="Artist" value={artist} onChange={(e) => setArtist(e.target.value)} />
                <TextField size="small" label="Label" value={label} onChange={(e) => setLabel(e.target.value)} />
                <GenreSelect value={genre} onChange={setGenre} genres={genres} />
                <TextField size="small" label="BPM min" value={bpmLow} onChange={(e) => setBpmLow(e.target.value)} sx={{ width: 100 }} />
                <TextField size="small" label="BPM max" value={bpmHigh} onChange={(e) => setBpmHigh(e.target.value)} sx={{ width: 100 }} />
                <TextField select size="small" label="Sort" value={sort} onChange={(e) => setSort(e.target.value)} sx={{ minWidth: 150 }}>
                  {SORTS.map(([v, l]) => <MenuItem key={v} value={v}>{l}</MenuItem>)}
                </TextField>
              </Box>
            </Collapse>
            {activeChips.length > 0 && (
              <Box sx={{ display: 'flex', gap: 0.75, mt: 1, overflowX: 'auto', pb: 0.5 }}>
                {activeChips.map((c, i) => (
                  <Chip key={i} label={c.label} onDelete={c.clear} size="small" sx={{ flex: 'none' }} />
                ))}
              </Box>
            )}
          </Box>
        ) : tab === 1 ? (
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1.5 }}>
            <Typography variant="body2" color="text.secondary">
              Mixing out of <strong>{selKey}</strong>
            </Typography>
            <Wheel selected={selKey} onPick={setSelKey} />
            <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 1, alignItems: 'center' }}>
              <GenreSelect value={hGenre} onChange={setHGenre} genres={genres} />
              <TextField size="small" label="BPM min" value={hBpmLow} onChange={(e) => setHBpmLow(e.target.value)} sx={{ width: 100 }} />
              <TextField size="small" label="BPM max" value={hBpmHigh} onChange={(e) => setHBpmHigh(e.target.value)} sx={{ width: 100 }} />
              <Button variant="contained" onClick={runHarmonic} disabled={busy}>Find compatible</Button>
            </Box>
          </Box>
        ) : (
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
            <Typography variant="body2" color="text.secondary">
              {downloads.length} downloaded this device
            </Typography>
            {downloads.length > 0 && (
              <Button size="small" color="inherit" onClick={() => setDownloads([])}>Clear list</Button>
            )}
          </Box>
        )}

        {error && <Alert severity="error" sx={{ mt: 2 }}>{error}</Alert>}
      </Box>

      <Box sx={{ flex: 1, minHeight: 0, px: 2, pt: 2, pb: current ? 12 : 2, display: 'flex', flexDirection: 'column' }}>
        <Paper variant="outlined" sx={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
          <TableContainer sx={{ flex: 1 }}>
            <Table size="small" stickyHeader>
              <TableHead>
                <TableRow>
                  <TableCell padding="checkbox" />
                  {COLUMNS.map((col) => (
                    <TableCell key={col.key} align={col.align}>
                      {col.sortable ? (
                        <TableSortLabel
                          active={sortKey === col.key}
                          direction={sortKey === col.key ? order : 'asc'}
                          onClick={() => handleSort(col.key)}
                        >
                          {col.label}
                        </TableSortLabel>
                      ) : (
                        col.label
                      )}
                    </TableCell>
                  ))}
                  <TableCell padding="checkbox" />
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((t, i) => {
                  const playing = current?.id === t.id
                  const kc = camelotColor(t.key)
                  return (
                    <TableRow key={t.id} hover selected={playing}>
                      <TableCell padding="checkbox">
                        <IconButton size="small" color="primary" onClick={() => setCurrent(t)}>
                          {playing && pStatus.loading ? (
                            <CircularProgress size={16} />
                          ) : playing && pStatus.playing ? (
                            <PauseIcon fontSize="small" />
                          ) : (
                            <PlayArrowIcon fontSize="small" />
                          )}
                        </IconButton>
                      </TableCell>
                      <TableCell>{i + 1}</TableCell>
                      <TableCell sx={{ fontWeight: 600, maxWidth: 260 }}>{t.title}</TableCell>
                      <TableCell sx={{ maxWidth: 180, color: 'text.secondary' }}>{t.artists}</TableCell>
                      <TableCell sx={{ maxWidth: 140, color: 'text.secondary' }}>{t.label}</TableCell>
                      <TableCell sx={{ color: 'text.secondary' }}>{t.genre}</TableCell>
                      <TableCell align="center">{t.bpm ?? ''}</TableCell>
                      <TableCell align="center">
                        {t.key && kc && (
                          <Chip size="small" label={t.key} sx={{ bgcolor: kc.bg, color: kc.fg, fontWeight: 700, height: 22 }} />
                        )}
                      </TableCell>
                      <TableCell align="center" sx={{ color: 'text.secondary', whiteSpace: 'nowrap' }}>{t.length ?? ''}</TableCell>
                      <TableCell padding="checkbox">
                        <IconButton size="small" onClick={() => download(t)} disabled={downloading === t.id}>
                          {downloading === t.id ? <CircularProgress size={16} /> : <DownloadIcon fontSize="small" />}
                        </IconButton>
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
          </TableContainer>
          {rows.length === 0 && (
            <Typography color="text.secondary" sx={{ p: 4, textAlign: 'center' }}>
              {busy
                ? 'Searching…'
                : tab === 0
                  ? 'Search for a title or artist to get started.'
                  : tab === 1
                    ? 'Pick a key and find compatible tracks.'
                    : 'Tracks you download appear here.'}
            </Typography>
          )}
        </Paper>
        {tab === 0 && totalPages > 1 && (
          <Box sx={{ display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 2, py: 1 }}>
            <Pagination count={totalPages} page={page} onChange={(_, p) => runSearch(p)} size="small" color="primary" />
            <Typography variant="caption" color="text.secondary">{count.toLocaleString()} tracks</Typography>
          </Box>
        )}
      </Box>

      <WavePlayer
        track={current}
        autoplay={autoplay}
        onToggleAutoplay={() => setAutoplay((a) => !a)}
        onEnded={playNext}
        onClose={() => setCurrent(null)}
        onStatus={(loading, playing) => setPStatus({ loading, playing })}
      />
    </Box>
  )
}
