const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

// Makes "lucide-#{ICON}" classes available, mirroring the heroicons plugin.
// The icon set itself is managed by mix.exs (the :lucide dep, sparse "icons").
//
// Icons are named exactly as the files in the lucide repo — kebab-case, and
// canonical rather than aliased. Two renames worth remembering when porting
// from lucide-react: <Home /> is `lucide-house`, <Loader2 /> is
// `lucide-loader-circle`.
//
// Lucide is a stroke-based set: the SVGs carry stroke="currentColor" with no
// fill. Inside a CSS mask the stroke renders opaque, so the alpha mask is the
// icon outline and `background-color: currentColor` tints it — the same
// mechanism heroicons uses, and it inherits text color the same way.
module.exports = plugin(function ({ matchComponents, theme }) {
  let iconsDir = path.join(__dirname, "../../deps/lucide/icons")
  let values = {}

  fs.readdirSync(iconsDir).forEach((file) => {
    if (!file.endsWith(".svg")) return
    let name = path.basename(file, ".svg")
    values[name] = { name, fullPath: path.join(iconsDir, file) }
  })

  matchComponents(
    {
      lucide: ({ name, fullPath }) => {
        let content = fs
          .readFileSync(fullPath)
          .toString()
          .replace(/\r?\n|\r/g, " ")
          .replace(/\s+/g, " ")
        content = encodeURIComponent(content)

        return {
          [`--lucide-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
          "-webkit-mask": `var(--lucide-${name})`,
          mask: `var(--lucide-${name})`,
          "mask-repeat": "no-repeat",
          "mask-size": "contain",
          "mask-position": "center",
          "background-color": "currentColor",
          "vertical-align": "middle",
          display: "inline-block",
          // Overridable by w-*/h-* utilities, which win on cascade order.
          width: theme("spacing.6"),
          height: theme("spacing.6"),
        }
      },
    },
    { values },
  )
})
