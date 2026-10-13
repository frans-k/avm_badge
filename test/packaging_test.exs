defmodule PackagingTest do
  use ExUnit.Case, async: true

  test "no dependency is resolved from a local path" do
    offenders =
      for {name, opts} <- Mix.Project.config()[:deps],
          is_list(opts),
          Keyword.has_key?(opts, :path),
          do: name

    assert offenders == [],
           "path deps do not exist on a collaborator's machine: #{inspect(offenders)}"
  end

  test "every git dependency is pinned to a full SHA" do
    unpinned =
      for {name, opts} <- Mix.Project.config()[:deps],
          is_list(opts),
          Keyword.has_key?(opts, :git) or Keyword.has_key?(opts, :github),
          not (is_binary(Keyword.get(opts, :ref)) and byte_size(Keyword.get(opts, :ref)) == 40),
          do: name

    assert unpinned == [],
           "a floating ref makes builds irreproducible: #{inspect(unpinned)}"
  end

  @root Path.expand("..", __DIR__)

  test "every generated font is one the firmware actually loads" do
    generated =
      Path.wildcard(Path.join(@root, "priv/fonts/*.uf"))
      |> Enum.map(&Path.basename(&1, ".uf"))
      |> Enum.sort()

    assert generated == ["dogica", "pixel_operator", "w95fa"]
  end

  test "asset sources live in the repo" do
    for path <- ["assets/src/fonts", "assets/src/icons"] do
      assert File.dir?(Path.join(@root, path)), "#{path} is missing"
    end

    assert File.exists?(Path.join(@root, "assets/src/icons/rickroll-roll.gif"))
  end

  @tag :regenerates_assets
  test "mkfonts.sh reproduces the committed fonts byte for byte" do
    before =
      for f <- Path.wildcard(Path.join(@root, "priv/fonts/*.uf")),
          into: %{},
          do: {Path.basename(f), File.read!(f)}

    {_, 0} =
      System.cmd(Path.join(@root, "tools/mkfonts.sh"), [], cd: @root, stderr_to_stdout: true)

    rebuilt =
      for f <- Path.wildcard(Path.join(@root, "priv/fonts/*.uf")),
          into: %{},
          do: {Path.basename(f), File.read!(f)}

    assert before == rebuilt
  end

  test "priv holds exactly the files the firmware reads at runtime" do
    priv = Path.join(@root, "priv")

    files =
      Path.wildcard(Path.join(priv, "**/*.{rgba,uf}"))
      |> Enum.map(&Path.relative_to(&1, priv))
      |> Enum.sort()

    frames =
      Enum.map(0..15, &"rickroll/frame#{String.pad_leading("#{&1}", 2, "0")}@48x48.rgba")

    fonts = ["fonts/dogica.uf", "fonts/pixel_operator.uf", "fonts/w95fa.uf"]
    [logo] = Path.wildcard(Path.join(priv, "logo/goatmire@*.rgba"))

    assert files == Enum.sort(frames ++ fonts ++ [Path.relative_to(logo, priv)])
  end

  test "font and root licences are bundled" do
    bundled =
      Path.wildcard(Path.join(@root, "LICENSES/*"))
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    expected = ["dogica-OFL-1.1.txt", "pixel_operator-CC0-1.0.txt", "w95fa-OFL-1.1.txt"]

    assert bundled == expected,
           "LICENSES directory missing or has unexpected files: #{inspect(bundled)}"

    assert File.exists?(Path.join(@root, "LICENSE")),
           "root LICENSE file is missing"
  end

  test "the expected base image tag is recorded" do
    tag = @root |> Path.join("BASE_IMAGE") |> File.read!() |> String.trim()
    assert tag =~ ~r/^badge-v\d+$/, "BASE_IMAGE must name a release tag, got: #{tag}"
  end
end
