# AtomVM's :atomvm module, serving the firmware's priv/ from disk.
defmodule :atomvm do
  @moduledoc false

  def read_priv(:avm_badge, path) do
    case File.read(Path.join(Badge.Sim.priv(), to_string(path))) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> :undefined
    end
  end
end
