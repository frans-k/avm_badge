# AtomVM's :atomvm module is absent on the host; serve priv/ from disk,
# answering `:undefined` for a missing file as the device does. The simulator
# target compiles its own.
unless Code.ensure_loaded?(:atomvm) do
  defmodule :atomvm do
    @priv Path.expand("../priv", __DIR__)

    def read_priv(:avm_badge, path) do
      case File.read(Path.join(@priv, List.to_string(path))) do
        {:ok, bytes} -> bytes
        {:error, _reason} -> :undefined
      end
    end
  end
end

ExUnit.configure(exclude: [:regenerates_assets])
ExUnit.start()
