defmodule :spi do
  @moduledoc false

  # As AtomVM's `spi:write/3`: `ok`, or `{error, Reason}` for a transaction it
  # cannot send. The firmware handles both, so the stand-in returns both.
  def write(_spi, :pixels, %{write_data: data}) when is_binary(data), do: :ok
  def write(_spi, _device, _transaction), do: {:error, :badarg}
end
