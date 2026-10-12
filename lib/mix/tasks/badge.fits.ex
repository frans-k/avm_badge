defmodule Mix.Tasks.Badge.Fits do
  @shortdoc "Refuses a firmware that outgrows its packbeam slot"

  @moduledoc """
  Checks `avm_badge.avm`, written by `mix atomvm.packbeam`, against the
  1120K `main.avm` partition (0x118000 = 1_146_880 bytes).

      mix badge.fits
  """

  use Mix.Task

  @avm "avm_badge.avm"
  @limit 1_146_880

  @impl Mix.Task
  def run(_args) do
    size = File.stat!(@avm).size

    Mix.shell().info("badge.fits: #{size}B of #{@limit}B")

    if size > @limit do
      Mix.raise("badge.fits: #{size}B of #{@limit}B, does not fit the packbeam slot")
    end
  rescue
    File.Error -> Mix.raise("badge.fits: no #{@avm}; run mix atomvm.packbeam")
  end
end
