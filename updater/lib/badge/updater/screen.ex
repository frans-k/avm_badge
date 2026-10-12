defmodule Badge.Updater.Screen do
  @moduledoc """
  The updater's one screen, drawn with AtomGL's built-in font so it needs
  nothing from the assets partition or the firmware's fonts.

  A view is a map:

    * `:status` — the line that says what is happening, always shown
    * `:detail` — a quieter line under it, such as the versions involved
    * `:progress` — a percentage for the bar, or `nil` for none
    * `:tone` — `:error` draws the status as a failure
    * `:warn` — `true` while flash is being written: the badge must stay on
    * `:footer` — what is installed, along the bottom
  """

  alias Badge.Display
  alias Badge.Hardware

  @compile {:no_warn_undefined, :spi}

  @bg 0x000000
  @fg 0xFFFFFF
  @dim 0x808080
  @track 0x404040
  @accent 0x00E5A0
  @warn 0xFFB000
  @error 0xFF5050

  @title "Firmware update"
  @warning "Do not turn off your badge"

  @char_w 8
  @margin 16
  @bar_h 12

  @title_y 36
  @status_y 84
  @detail_y 108
  @bar_y 140
  @warn_y 172
  @footer_y 216

  @doc "Opens the display SPI bus and the AtomGL port."
  @spec open() :: {module, port}
  def open do
    spi =
      :spi.open(%{
        bus_config: %{
          peripheral: Hardware.display_peripheral(),
          sclk: Hardware.display_sclk(),
          mosi: Hardware.display_mosi(),
          miso: Hardware.display_miso()
        },
        device_config: %{}
      })

    {Display.AtomGL, Display.AtomGL.open(spi)}
  end

  @doc "Draws a view."
  @spec show({module, port}, map) :: :ok
  def show(display, view), do: Display.update(display, items(view))

  @doc "The display list for a view, background last."
  @spec items(map) :: [tuple]
  def items(view) do
    width = Hardware.display_width()
    height = Hardware.display_height()

    status_colour = if Map.get(view, :tone) == :error, do: @error, else: @fg

    :lists.flatten([
      line(@title, @title_y, @accent, width),
      line(Map.fetch!(view, :status), @status_y, status_colour, width),
      line(Map.get(view, :detail), @detail_y, @dim, width),
      bar(Map.get(view, :progress), width),
      if(Map.get(view, :warn, false), do: line(@warning, @warn_y, @warn, width), else: []),
      line(Map.get(view, :footer), @footer_y, @dim, width),
      {:rect, 0, 0, width, height, @bg}
    ])
  end

  defp line(nil, _y, _colour, _width), do: []

  defp line(text, y, colour, width) do
    {:text, centred(text, width), y, :default16px, colour, @bg, fit(text, width)}
  end

  # Fill first, so the track shows through as the remainder.
  defp bar(percent, width) when is_integer(percent) do
    inner = width - 2 * @margin
    filled = div(inner * max(min(percent, 100), 0), 100)

    [
      {:rect, @margin, @bar_y, filled, @bar_h, @accent},
      {:rect, @margin, @bar_y, inner, @bar_h, @track}
    ]
  end

  defp bar(_none, _width), do: []

  defp centred(text, width), do: max(div(width - @char_w * byte_size(fit(text, width)), 2), 0)

  defp fit(text, width) do
    columns = div(width, @char_w)

    if byte_size(text) > columns, do: :binary.part(text, 0, columns), else: text
  end
end
