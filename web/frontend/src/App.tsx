import { useEffect, useState } from 'react'
import { api, camelotColor, downloadTrack, harmonicNeighbours } from './api'
import type { Genre, SearchResponse, Track } from './api'

/** Inline style for a Camelot key chip, coloured like the app's wheel. */
export function keyStyle(code: string | null) {
  const c = camelotColor(code)
  return c ? { background: c.bg, color: c.fg } : undefined
}
import { WavePlayer } from './WavePlayer'

function Logo({ size = 26 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden>
      {[6, 9, 12, 15, 18].map((x, i) => {
        const h = [8, 13, 18, 13, 8][i]
        return <rect key={x} x={x - 1.3} y={(24 - h) / 2} width="2.6" height={h} rx="1.3" fill="#0b8f57" />
      })}
    </svg>
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
    <form className="login" onSubmit={submit}>
      <div className="brand big">
        <Logo size={30} />
        <span>BeatPort Digger</span>
      </div>
      <p className="muted">Sign in with your Beatport account</p>
      <input placeholder="Username" value={username} onChange={(e) => setUsername(e.target.value)} autoFocus />
      <input placeholder="Password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
      <button disabled={busy || !username || !password}>{busy ? 'Signing in…' : 'Sign in'}</button>
      {error && <div className="error">{error}</div>}
      <p className="muted small">Your password is used once to get a token and is not stored.</p>
    </form>
  )
}

const SORTS = [
  ['-publish_date', 'Newest'],
  ['publish_date', 'Oldest'],
  ['-plays', 'Most played'],
  ['-downloads', 'Most downloaded'],
  ['name', 'Title'],
  ['bpm', 'BPM'],
]

function Wheel({ selected, onPick }: { selected: string; onPick: (code: string) => void }) {
  const neighbours = harmonicNeighbours(selected)
  const codes: string[] = []
  for (let n = 1; n <= 12; n++) for (const l of ['A', 'B']) codes.push(`${n}${l}`)
  return (
    <div className="wheel">
      {codes.map((c) => {
        const active = c === selected || neighbours.includes(c)
        const cc = camelotColor(c)!
        return (
          <button
            key={c}
            className={c === selected ? 'k sel' : 'k'}
            style={{ background: cc.bg, color: cc.fg, opacity: active ? 1 : 0.4 }}
            onClick={() => onPick(c)}
          >
            {c}
          </button>
        )
      })}
    </div>
  )
}

export default function App() {
  const [authed, setAuthed] = useState<boolean | null>(null)
  const [tab, setTab] = useState<'search' | 'harmonic'>('search')
  const [genres, setGenres] = useState<Genre[]>([])

  // Search state.
  const [title, setTitle] = useState('')
  const [artist, setArtist] = useState('')
  const [label, setLabel] = useState('')
  const [genre, setGenre] = useState('')
  const [bpmLow, setBpmLow] = useState('')
  const [bpmHigh, setBpmHigh] = useState('')
  const [sort, setSort] = useState('-publish_date')
  const [showFilters, setShowFilters] = useState(false)

  // Harmonic state.
  const [selKey, setSelKey] = useState('8A')
  const [hGenre, setHGenre] = useState('')
  const [hBpmLow, setHBpmLow] = useState('')
  const [hBpmHigh, setHBpmHigh] = useState('')

  const [results, setResults] = useState<Track[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [current, setCurrent] = useState<Track | null>(null)
  const [autoplay, setAutoplay] = useState(true)
  const [downloading, setDownloading] = useState<number | null>(null)

  useEffect(() => {
    api<{ authenticated: boolean }>('/api/status')
      .then((s) => setAuthed(s.authenticated))
      .catch(() => setAuthed(false))
  }, [])

  useEffect(() => {
    if (!authed) return
    api<{ genres: Genre[] }>('/api/genres')
      .then((g) => setGenres(g.genres))
      .catch(() => {})
  }, [authed])

  async function runSearch(e?: React.FormEvent) {
    e?.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const p = new URLSearchParams()
      if (title.trim()) p.set('title', title.trim())
      if (artist.trim()) p.set('artist', artist.trim())
      if (label.trim()) p.set('label', label.trim())
      if (genre) p.set('genre', genre)
      if (bpmLow.trim()) p.set('bpmLow', bpmLow.trim())
      if (bpmHigh.trim()) p.set('bpmHigh', bpmHigh.trim())
      p.set('sort', sort)
      const data = await api<SearchResponse>(`/api/search?${p.toString()}`)
      setResults(data.results)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Search failed')
    } finally {
      setBusy(false)
    }
  }

  async function runHarmonic() {
    setBusy(true)
    setError(null)
    try {
      const p = new URLSearchParams({ key: selKey })
      if (hGenre) p.set('genre', hGenre)
      if (hBpmLow.trim()) p.set('bpmLow', hBpmLow.trim())
      if (hBpmHigh.trim()) p.set('bpmHigh', hBpmHigh.trim())
      const data = await api<SearchResponse>(`/api/harmonic?${p.toString()}`)
      setResults(data.results)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Harmonic search failed')
    } finally {
      setBusy(false)
    }
  }

  function playNext() {
    if (!autoplay || !current) return
    const i = results.findIndex((t) => t.id === current.id)
    if (i >= 0 && i + 1 < results.length) setCurrent(results[i + 1])
  }

  async function download(t: Track) {
    setDownloading(t.id)
    setError(null)
    try {
      await downloadTrack(t)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Download failed')
    } finally {
      setDownloading(null)
    }
  }

  if (authed === null) return <div className="loading">Loading…</div>
  if (!authed) return <Login onDone={() => setAuthed(true)} />

  const genreOptions = (value: string, set: (v: string) => void) => (
    <select value={value} onChange={(e) => set(e.target.value)}>
      <option value="">Any genre</option>
      {genres.map((g) => (
        <option key={g.id} value={g.id}>
          {g.name}
        </option>
      ))}
    </select>
  )

  return (
    <div className="app">
      <header>
        <div className="brand">
          <Logo />
          <span>BeatPort Digger</span>
        </div>
        <div className="tabs">
          <button className={tab === 'search' ? 'on' : ''} onClick={() => setTab('search')}>
            Search
          </button>
          <button className={tab === 'harmonic' ? 'on' : ''} onClick={() => setTab('harmonic')}>
            Harmonic
          </button>
        </div>
      </header>

      {tab === 'search' ? (
        <form className="controls" onSubmit={runSearch}>
          <div className="searchbar">
            <input placeholder="Search title" value={title} onChange={(e) => setTitle(e.target.value)} />
            <button type="button" className="ghost" onClick={() => setShowFilters((s) => !s)}>
              Filters
            </button>
            <button disabled={busy}>{busy ? '…' : 'Search'}</button>
          </div>
          {showFilters && (
            <div className="filters">
              <input placeholder="Artist" value={artist} onChange={(e) => setArtist(e.target.value)} />
              <input placeholder="Label" value={label} onChange={(e) => setLabel(e.target.value)} />
              {genreOptions(genre, setGenre)}
              <input className="bpm" placeholder="BPM min" value={bpmLow} onChange={(e) => setBpmLow(e.target.value)} />
              <input className="bpm" placeholder="BPM max" value={bpmHigh} onChange={(e) => setBpmHigh(e.target.value)} />
              <select value={sort} onChange={(e) => setSort(e.target.value)}>
                {SORTS.map(([v, l]) => (
                  <option key={v} value={v}>
                    {l}
                  </option>
                ))}
              </select>
            </div>
          )}
        </form>
      ) : (
        <div className="controls">
          <div className="hrow">
            <span className="muted">Mixing out of</span> <strong>{selKey}</strong>
          </div>
          <Wheel selected={selKey} onPick={setSelKey} />
          <div className="filters">
            {genreOptions(hGenre, setHGenre)}
            <input className="bpm" placeholder="BPM min" value={hBpmLow} onChange={(e) => setHBpmLow(e.target.value)} />
            <input className="bpm" placeholder="BPM max" value={hBpmHigh} onChange={(e) => setHBpmHigh(e.target.value)} />
            <button onClick={runHarmonic} disabled={busy}>
              {busy ? '…' : 'Find compatible'}
            </button>
          </div>
        </div>
      )}

      {error && <div className="error banner">{error}</div>}

      <main>
        {results.length === 0 && !busy && (
          <div className="muted center">
            {tab === 'search' ? 'Search for a title or artist to get started.' : 'Pick a key and find compatible tracks.'}
          </div>
        )}
        <ul className="tracks">
          {results.map((t) => {
            const playing = current?.id === t.id
            return (
              <li key={t.id} className={playing ? 'playing' : ''}>
                <button className="play" onClick={() => setCurrent(t)} title="Preview">
                  {playing ? '❚❚' : '▶'}
                </button>
                {t.key && (
                  <span className="key" style={keyStyle(t.key)}>
                    {t.key}
                  </span>
                )}
                <div className="meta">
                  <div className="title">{t.title}</div>
                  <div className="sub">
                    {t.artists}
                    {t.label ? ` · ${t.label}` : ''}
                  </div>
                </div>
                <span className="bpm-tag">{t.bpm ? `${t.bpm}` : ''}</span>
                <button className="dl" onClick={() => download(t)} disabled={downloading === t.id} title="Download">
                  {downloading === t.id ? '…' : '↓'}
                </button>
              </li>
            )
          })}
        </ul>
      </main>

      <WavePlayer
        track={current}
        autoplay={autoplay}
        onToggleAutoplay={() => setAutoplay((a) => !a)}
        onEnded={playNext}
        onClose={() => setCurrent(null)}
      />
    </div>
  )
}
