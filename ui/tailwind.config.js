/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        // Midnight Network palette
        night: {
          50:  '#f0f4ff',
          100: '#dde6ff',
          200: '#c3d0ff',
          300: '#9db0ff',
          400: '#7487ff',
          500: '#4f5fff',
          600: '#3a3ef5',
          700: '#2e2fd8',
          800: '#272aae',
          900: '#252988',
          950: '#161751',
        },
        // Midnight ZK dark bg
        void: {
          900: '#0d0e1a',
          800: '#13152b',
          700: '#1a1d3a',
          600: '#232650',
        },
        neon: {
          cyan: '#5ef2ff',
          magenta: '#ff4fd8',
        },
      },
      fontFamily: {
        sans: ['Space Grotesk', 'Segoe UI', 'sans-serif'],
        mono: ['JetBrains Mono', 'Fira Code', 'monospace'],
      },
    },
  },
  plugins: [],
};
