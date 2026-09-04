/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        darkBg: "#0B0F19",
        darkCard: "#111827",
        darkBorder: "#1F2937",
        accentCyan: "#06B6D4",
        accentGreen: "#10B981",
        accentPurple: "#8B5CF6",
      }
    },
  },
  plugins: [],
}
