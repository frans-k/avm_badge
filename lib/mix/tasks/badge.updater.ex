defmodule Mix.Tasks.Badge.Updater do
  @shortdoc "Builds the updater and writes it to the badge's updater.avm"

  @moduledoc """
  Builds `updater/` (its own Mix project) and writes the packbeam to the
  `updater.avm` partition at 0x278000.

      mix badge.updater               # build and flash
      mix badge.updater --build-only  # build and size-check, write nothing

  The firmware in `main.avm` and NVS are left alone. The updater is not
  updated over the air, so a change to it reaches a badge only this way.
  """

  use Mix.Task

  @project "updater"
  @avm "updater/badge_updater.avm"
  @offset 0x278000
  @limit 0x30000

  @impl Mix.Task
  def run(args) do
    {options, _rest} = OptionParser.parse!(args, strict: [build_only: :boolean])

    build()
    fits!()

    unless options[:build_only] do
      Mix.Tasks.Badge.Base.write_flash([{@offset, @avm}])
    end
  end

  defp build do
    for task <- [["deps.get"], ["atomvm.packbeam"]] do
      case System.cmd("mix", task, cd: @project, into: IO.stream(:stdio, :line)) do
        {_, 0} -> :ok
        {_, code} -> Mix.raise("badge.updater: mix #{Enum.join(task, " ")} exited #{code}")
      end
    end
  end

  defp fits! do
    size = File.stat!(@avm).size
    Mix.shell().info("badge.updater: #{size}B of #{@limit}B")

    if size > @limit do
      Mix.raise("badge.updater: #{size}B does not fit the #{@limit}B updater partition")
    end
  end
end
