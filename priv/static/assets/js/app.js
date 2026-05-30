// You — Identity & Access Management

// ── Theme Toggle Hook ────────────────────────────

const ThemeToggle = {
  mounted() {
    this.el.addEventListener("click", () => {
      const isDark = document.documentElement.classList.contains("dark");
      setTheme(isDark ? "light" : "dark");
    });
  },
};

// ── Theme helpers ────────────────────────────────

function getTheme() {
  return localStorage.getItem("you-theme") || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
}

function setTheme(theme) {
  localStorage.setItem("you-theme", theme);
  applyTheme(theme);
}

function applyTheme(theme) {
  const isDark = theme === "dark";
  document.documentElement.classList.toggle("dark", isDark);
  document.documentElement.setAttribute("data-theme", isDark ? "you-dark" : "you");
}

// Listen for system preference changes (only if no explicit preference is set)
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (e) => {
  if (!localStorage.getItem("you-theme")) {
    applyTheme(e.matches ? "dark" : "light");
  }
});

// ── Phoenix LiveView – setup ────────────────────

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ThemeToggle },
});

// Connect if we are on a LiveView page
liveSocket.connect();

// Expose liveSocket on window for debugging
window.liveSocket = liveSocket;
