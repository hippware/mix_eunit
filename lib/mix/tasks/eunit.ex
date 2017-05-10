defmodule Mix.Tasks.Eunit do
  use Mix.Task

  @moduledoc """
  Runs the eunit tests for a project.

  This task compiles the project and its tests in the test environment, starts
  the application (via `mix app.start`), then runs eunit tests.

  This task works recursively in umbrella projects.

  ## Command line options

  A list of patterns can be given after the task name in order to select the
  tests to run:

  ```
  mix eunit foo* bar*
  ```

  The runner automatically adds \".erl\" to the patterns.

  ## Command line options

  * `--verbose`, `-v` - run eunit with the :verbose option
  * `--cover`, `-c` - create a coverage report after running the tests
  * `--profile`, `-p` - show a list of the 10 slowest tests
  * `--start` - start applications after compilation
  * `--no-color` - disable color output
  * `--force` - force compilation regardless of compilation times
  * `--no-compile` - do not compile even if files require compilation
  * `--no-archives-check` - do not check archives
  * `--no-deps-check` - do not check dependencies
  * `--no-elixir-version-check` - do not check Elixir version

  The `verbose`, `cover`, `profile`, `start` and `color` switches can be set in
  the `mix.exs` file and will apply to every invocation of this task. Switches
  set on the command line will override any settings in the mixfile.

  ```
  def project do
    [
      # ...
      eunit: [
        verbose: false,
        cover: true,
        profile: true,
        start: true,
        color: false
      ]
    ]
  end
  ```

  ## Test search path

  All \".erl\" files in the src and test directories are considered.

  """
  @shortdoc "Runs a project's eunit tests"
  @preferred_cli_env :test
  @recursive true

  @switches [
    color: :boolean, cover: :boolean, profile: :boolean, verbose: :boolean,
    start: :boolean, compile: :boolean, force: :boolean, deps_check: :boolean,
    archives_check: :boolean, elixir_version_check: :boolean
  ]

  @aliases [v: :verbose, p: :profile, c: :cover]

  @default_cover_opts [output: "cover", tool: Mix.Tasks.Test.Cover]

  def run(args) do
    project = Mix.Project.config
    options = parse_options(args, project)

    # add test directory to compile paths and add
    # compiler options for test
    post_config = eunit_post_config(project)
    modify_project_config(post_config)

    if Keyword.get(options, :compile, true) do
      Mix.Tasks.Compile.run(args)
    end

    if Keyword.get(options, :start, false) do
      # start the application
      Mix.shell.print_app
      Mix.Task.run "app.start", args
    end

    # start cover
    cover_state = start_cover_tool(options[:cover], project)

    # run the actual tests
    modules =
      post_config[:erlc_paths]
      |> test_modules(options[:patterns])
      |> Enum.map(&module_name_from_path/1)
      |> Enum.map(fn m -> {:module, m} end)

    eunit_opts = get_eunit_opts(options, post_config)
    result = :eunit.test(modules, eunit_opts)

    case result do
      :error -> Mix.raise "mix eunit failed"
      :ok -> :ok
    end

    analyze_coverage(cover_state)
  end

  defp parse_options(args, project) do
    {switches, argv} =
      OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    patterns = case argv do
                 [] -> ["*"]
                 p -> p
               end

    eunit_opts = case switches[:verbose] do
                   true -> [:verbose]
                   _ -> []
                 end

    (project[:eunit] || [])
    |> Keyword.take([:verbose, :profile, :cover, :start, :color])
    |> Keyword.merge(switches)
    |> Keyword.put(:eunit_opts, eunit_opts)
    |> Keyword.put(:patterns, patterns)
  end

  defp eunit_post_config(existing_config) do
    [erlc_paths: existing_config[:erlc_paths] ++ ["test"],
     erlc_options: maybe_add_test_define(existing_config[:erlc_options]),
     eunit_opts: existing_config[:eunit_opts] || []]
  end

  defp maybe_add_test_define(opts) do
    if Enum.member?(opts, {:d, :TEST}) do
      opts
    else
      [{:d, :TEST} | opts]
    end
  end

  defp get_eunit_opts(options, post_config) do
    eunit_opts = options[:eunit_opts] ++ post_config[:eunit_opts]
    maybe_add_formatter(eunit_opts, options[:profile], options[:color] || true)
  end

  defp maybe_add_formatter(opts, profile, color) do
    if Keyword.has_key?(opts, :report) do
      opts
    else
      format_opts = color_opt(color) ++ profile_opt(profile)
      [:no_tty, {:report, {:eunit_progress, format_opts}} | opts]
    end
  end

  defp color_opt(true), do: [:colored]
  defp color_opt(_), do: []

  defp profile_opt(true), do: [:profile]
  defp profile_opt(_), do: []

  defp modify_project_config(post_config) do
    %{name: name, file: file} = Mix.Project.pop
    Mix.ProjectStack.post_config(post_config)
    Mix.Project.push name, file
  end

  defp test_modules(directories, patterns) do
    all_modules =
      directories
      |> erlang_source_files(patterns)
      |> Enum.map(&module_name_from_path/1)
      |> Enum.uniq

    remove_test_duplicates(all_modules, all_modules, [])
  end

  defp erlang_source_files(directories, patterns) do
    patterns
    |> Enum.map(fn p -> Mix.Utils.extract_files(directories, p <> ".erl") end)
    |> Enum.concat
    |> Enum.uniq
  end

  defp module_name_from_path(p) do
    Path.basename(p, ".erl") |> String.to_atom
  end

  defp remove_test_duplicates([], _all_module_names, accum) do
    accum
  end
  defp remove_test_duplicates([module | rest], all_module_names, accum) do
    module = Atom.to_string(module)
    if tests_module?(module) &&
      Enum.member?(all_module_names, without_test_suffix(module)) do
      remove_test_duplicates(rest, all_module_names, accum)
    else
      remove_test_duplicates(rest, all_module_names, [module | accum])
    end
  end

  defp tests_module?(module_name) do
    String.match?(module_name, ~r/_tests$/)
  end

  defp without_test_suffix(module_name) do
    module_name
    |> String.replace(~r/_tests$/, "")
    |> String.to_atom
  end

  # coverage was disabled
  defp start_cover_tool(nil, _project), do: nil
  defp start_cover_tool(false, _project), do: nil
  # set up the cover tool
  defp start_cover_tool(_cover_switch, project) do
    compile_path = Mix.Project.compile_path(project)
    cover = Keyword.merge(@default_cover_opts, project[:test_coverage] || [])
    # returns a callback
    cover[:tool].start(compile_path, cover)
  end

  # no cover tool was specified
  defp analyze_coverage(nil), do: :ok
  # run the cover callback
  defp analyze_coverage(cb), do: cb.()
end
