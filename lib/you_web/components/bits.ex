defmodule YouWeb.Components.Bits do
  @moduledoc """
  Small presentational pieces shared by the landing page and the console.

  These are deliberately *not* in `YouWeb.Components.Base` — that layer is
  for behavior-first Base UI primitives. Everything here is pure markup with no
  interaction contract to get right, and several encode You's own semantics
  (what colour "live" is) rather than a generic UI concept.

  Ported from the prototype's `bits.tsx`.
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  @status_color %{
    "live" => "bg-signal-live",
    "running" => "bg-signal-ok",
    "idle" => "bg-signal-warn",
    "error" => "bg-signal-down",
    "terminated" => "bg-muted-foreground",
    "healthy" => "bg-signal-ok",
    "degraded" => "bg-signal-warn",
    "down" => "bg-signal-down"
  }

  @status_label %{
    "live" => "live",
    "running" => "run",
    "idle" => "idle",
    "error" => "err",
    "terminated" => "term"
  }

  @doc """
  Coloured status dot. `live` pulses; everything else is static.
  """
  attr :status, :string, required: true, values: Map.keys(@status_color)
  attr :class, :any, default: nil

  def status_dot(assigns) do
    assigns =
      assign(assigns, :classes, [
        "inline-block h-2 w-2 rounded-full",
        @status_color[assigns.status],
        assigns.status == "live" && "animate-pulse-live",
        assigns.class
      ])

    ~H"""
    <span class={cx(@classes)} />
    """
  end

  @doc """
  Status dot plus its short label, in the console's table voice.
  """
  attr :status, :string, required: true, values: Map.keys(@status_label)

  def status_badge(assigns) do
    text_class =
      case assigns.status do
        "error" -> "text-signal-down"
        "live" -> "text-signal-live"
        _ -> nil
      end

    assigns =
      assign(assigns,
        text_class: text_class,
        label: @status_label[assigns.status] || assigns.status
      )

    ~H"""
    <span class="inline-flex items-center gap-1.5 font-mono text-xs">
      <.status_dot status={@status} />
      <span class={@text_class}>{@label}</span>
    </span>
    """
  end

  @doc """
  Section eyebrow — the small cyan rule-and-caption above a heading.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def eyebrow(assigns) do
    ~H"""
    <div class={
      cx([
        "mb-3 inline-flex items-center gap-2 font-mono text-xs uppercase tracking-widest text-azure-brand",
        @class
      ])
    }>
      <span class="h-px w-6 bg-azure-brand/50" />
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Dependency-free sparkline. Points are computed server-side into an SVG path,
  which is cheaper than shipping a charting library for a 100x28 graphic.
  """
  attr :data, :list, required: true
  attr :area, :boolean, default: true
  attr :stroke, :string, default: "hsl(var(--brand-azure))"
  attr :class, :any, default: nil

  def sparkline(assigns) do
    assigns = assign(assigns, :paths, sparkline_paths(assigns.data))

    ~H"""
    <svg viewBox="0 0 100 28" preserveAspectRatio="none" class={cx(["w-full", @class])}>
      <path :if={@area} d={@paths.fill} fill={@stroke} opacity="0.12" />
      <path
        d={@paths.line}
        fill="none"
        stroke={@stroke}
        stroke-width="1.5"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  defp sparkline_paths([]), do: %{line: "", fill: ""}
  defp sparkline_paths([_single]), do: %{line: "", fill: ""}

  defp sparkline_paths(data) do
    {w, h} = {100, 28}
    min = Enum.min(data)
    span = max(Enum.max(data) - min, 1)
    last = length(data) - 1

    line =
      data
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {v, i} ->
        x = i / last * w
        y = h - (v - min) / span * (h - 4) - 2
        "#{if i == 0, do: "M", else: "L"}#{fmt(x)},#{fmt(y)}"
      end)

    %{line: line, fill: "#{line} L#{w},#{h} L0,#{h} Z"}
  end

  defp fmt(n), do: :erlang.float_to_binary(n / 1, decimals: 1)

  @doc """
  Console metric tile, optionally with a delta and a sparkline.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :delta, :string, default: nil
  attr :spark, :list, default: nil
  attr :accent, :string, default: nil, values: [nil, "live", "ok"]

  def metric_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-border bg-card p-4">
      <div class="text-xs font-medium uppercase tracking-wide text-muted-foreground">{@label}</div>
      <div class="mt-1 flex items-baseline gap-2">
        <span class={
          cx([
            "font-mono text-2xl font-semibold tabular-nums",
            @accent == "live" && "text-signal-live"
          ])
        }>
          {@value}
        </span>
        <span :if={@delta} class="text-xs font-medium text-signal-ok">{@delta}</span>
      </div>
      <div :if={@spark} class="mt-3 h-7">
        <.sparkline data={@spark} />
      </div>
    </div>
    """
  end
end
