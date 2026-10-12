defmodule Badge.Updater.Screen do
  @moduledoc """
  The updater's one screen: a title, a status line, and a progress bar while a
  download runs. Drawn with AtomGL's built-in font, so it needs nothing from
  the assets partition or the firmware's fonts.
  """

  alias Badge.Display
  alias Badge.Hardware

  @compile {:no_warn_undefined, :spi}

  @bg 0x000000
  @fg 0xFFFFFF
  @dim 0x606060
  @accent 0x00E5A0
  @error 0xFF5050

  @char_w 8
  @margin 16
  @bar_h 12

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

  @doc """
  Draws the screen. `progress` is a percentage, `nil` for no bar, or
  `:error` to show the status line as a failure.
  """
  @spec show({module, port}, binary, binary, non_neg_integer | nil | :error) :: :ok
  def show(display, title, status, progress \\ nil) do
    Display.update(display, items(title, status, progress))
  end

  @doc "The display list for a screen, background last."
  @spec items(binary, binary, non_neg_integer | nil | :error) :: [tuple]
  def items(title, status, progress) do
    width = Hardware.display_width()
    height = Hardware.display_height()

    colour = if progress == :error, do: @error, else: @fg

    [
      {:text, centred(title, width), 80, :default16px, @accent, @bg, title},
      {:text, centred(status, width), 112, :default16px, colour, @bg, status}
    ] ++ bar(progress, width) ++ [{:rect, 0, 0, width, height, @bg}]
  end

  defp bar(percent, width) when is_integer(percent) do
    inner = width - 2 * @margin
    filled = div(inner * min(percent, 100), 100)

    [
      {:rect, @margin, 150, filled, @bar_h, @accent},
      {:rect, @margin, 150, inner, @bar_h, @dim}
    ]
  end

  defp bar(_none, _width), do: []

  defp centred(text, width), do: max(div(width - @char_w * byte_size(text), 2), 0)
end
