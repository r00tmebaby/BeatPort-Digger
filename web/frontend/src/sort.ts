import type { Track } from './api'

export type SortKey =
  | 'index'
  | 'title'
  | 'artists'
  | 'label'
  | 'genre'
  | 'bpm'
  | 'key'
  | 'length'
export type Order = 'asc' | 'desc'

function lengthSeconds(value: string | null): number {
  if (!value) return -1
  return value.split(':').reduce((total, part) => total * 60 + (parseInt(part, 10) || 0), 0)
}

// Camelot codes sort round the wheel, not as text: 10A must follow 9A.
function keyRank(code: string | null): number {
  const m = code ? /^(\d{1,2})([AB])$/.exec(code) : null
  if (!m) return 1 << 20
  return parseInt(m[1], 10) * 2 + (m[2] === 'A' ? 0 : 1)
}

export function sortTracks(tracks: Track[], key: SortKey, order: Order): Track[] {
  if (key === 'index') return tracks
  const dir = order === 'asc' ? 1 : -1
  const cmp = (a: Track, b: Track): number => {
    switch (key) {
      case 'title':
        return a.title.toLowerCase().localeCompare(b.title.toLowerCase())
      case 'artists':
        return a.artists.toLowerCase().localeCompare(b.artists.toLowerCase())
      case 'label':
        return a.label.toLowerCase().localeCompare(b.label.toLowerCase())
      case 'genre':
        return a.genre.toLowerCase().localeCompare(b.genre.toLowerCase())
      case 'bpm':
        return (a.bpm ?? -1) - (b.bpm ?? -1)
      case 'key':
        return keyRank(a.key) - keyRank(b.key)
      case 'length':
        return lengthSeconds(a.length) - lengthSeconds(b.length)
      default:
        return 0
    }
  }
  return [...tracks].sort((a, b) => cmp(a, b) * dir)
}
