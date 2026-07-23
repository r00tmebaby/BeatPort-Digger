import { createTheme } from '@mui/material/styles'

// Light Material theme with the app's green as the primary colour.
export const theme = createTheme({
  palette: {
    mode: 'light',
    primary: { main: '#0b8f57', dark: '#04663f', contrastText: '#ffffff' },
    background: { default: '#f1f7f3', paper: '#ffffff' },
    text: { primary: '#11201a', secondary: '#5c7268' },
  },
  shape: { borderRadius: 10 },
  typography: {
    fontFamily:
      '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
  },
  components: {
    MuiTableCell: {
      styleOverrides: {
        root: { paddingTop: 6, paddingBottom: 6 },
        head: { fontWeight: 700, whiteSpace: 'nowrap' },
      },
    },
  },
})
