import { useEffect, useRef, useState } from 'react'

type Track = {
  id: number
  title: string
  artists: string
  label: string
  genre: string
  bpm: number | null
  key: string | null
  length: string | null
  badges: string[]
}

type SearchResponse = {
  count: number
  hasNext: boolean
  results: Track[]
}

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    ...init,
    headers: { 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error((data as { error?: string }).error ?? `Request failed (${res.status})`)
  return data as T
}

function Logo() {
  return (
    <svg width="26" height="26" viewBox="0 0 24 24" aria-hidden>
      {[6, 9, 12, 15, 18].map((x, i) => {
        const h = [8, 13, 18, 13, 8][i]
        return <rect key={x} x={x - 1.3} y={(24 - h) / 2} width="2.6" height={h} rx="1.3" fill="#01ff95" />
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
      await api('/api/login', {
        method: 'POST',
        body: JSON.stringify({ username, password }),
      })
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
        <Logo />
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

export default function App() {
  const [authed, setAuthed] = useState<boolean | null>(null)
  const [title, setTitle] = useState('')
  const [artist, setArtist] = useState('')
  const [results, setResults] = useState<Track[]>([])
  const [searching, setSearching] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [current, setCurrent] = useState<Track | null>(null)
  const [autoplay, setAutoplay] = useState(true)
  const audioRef = useRef<HTMLAudioElement>(null)

  useEffect(() => {
    api<{ authenticated: boolean }>('/api/status')
      .then((s) => setAuthed(s.authenticated))
      .catch(() => setAuthed(false))
  }, [])

  async function search(e?: React.FormEvent) {
    e?.preventDefault()
    setSearching(true)
    setError(null)
    try {
      const params = new URLSearchParams()
      if (title.trim()) params.set('title', title.trim())
      if (artist.trim()) params.set('artist', artist.trim())
      const data = await api<SearchResponse>(`/api/search?${params.toString()}`)
      setResults(data.results)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Search failed')
    } finally {
      setSearching(false)
    }
  }

  function play(track: Track) {
    setCurrent(track)
    const audio = audioRef.current
    if (audio) {
      audio.src = `/api/preview/${track.id}`
      audio.play().catch(() => {})
    }
  }

  function playNext() {
    if (!autoplay || !current) return
    const i = results.findIndex((t) => t.id === current.id)
    if (i >= 0 && i + 1 < results.length) play(results[i + 1])
  }

  if (authed === null) return <div className="loading">Loading…</div>
  if (!authed) return <Login onDone={() => setAuthed(true)} />

  return (
    <div className="app">
      <header>
        <div className="brand">
          <Logo />
          <span>BeatPort Digger</span>
        </div>
      </header>

      <form className="searchbar" onSubmit={search}>
        <input placeholder="Search title" value={title} onChange={(e) => setTitle(e.target.value)} />
        <input placeholder="Artist" value={artist} onChange={(e) => setArtist(e.target.value)} />
        <button disabled={searching}>{searching ? '…' : 'Search'}</button>
      </form>

      {error && <div className="error banner">{error}</div>}

      <main>
        {results.length === 0 && !searching && (
          <div className="muted center">Search for a title or artist to get started.</div>
        )}
        <ul className="tracks">
          {results.map((t) => {
            const playing = current?.id === t.id
            return (
              <li key={t.id} className={playing ? 'playing' : ''}>
                <button className="play" onClick={() => play(t)} title="Preview">
                  {playing ? '❚❚' : '▶'}
                </button>
                {t.key && <span className="key">{t.key}</span>}
                <div className="meta">
                  <div className="title">{t.title}</div>
                  <div className="sub">
                    {t.artists}
                    {t.label ? ` · ${t.label}` : ''}
                  </div>
                </div>
                <span className="bpm">{t.bpm ? `${t.bpm} BPM` : ''}</span>
              </li>
            )
          })}
        </ul>
      </main>

      <footer className={current ? 'player active' : 'player'}>
        {current && (
          <div className="now">
            {current.key && <span className="key">{current.key}</span>}
            <div className="meta">
              <div className="title">{current.title}</div>
              <div className="sub">{current.artists}</div>
            </div>
            <button
              className={autoplay ? 'auto on' : 'auto'}
              onClick={() => setAutoplay((a) => !a)}
              title={autoplay ? 'Autoplay on' : 'Autoplay off'}
            >
              ⏭
            </button>
          </div>
        )}
        <audio ref={audioRef} controls onEnded={playNext} />
      </footer>
    </div>
  )
}
