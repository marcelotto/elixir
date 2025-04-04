# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

defmodule Mix.Tasks.Escript.Build do
  use Mix.Task
  import Bitwise, only: [|||: 2]

  @shortdoc "Builds an escript for the project"
  @recursive true

  @moduledoc ~S"""
  Builds an escript for the project.

  An escript is an executable that can be invoked from the
  command line. An escript can run on any machine that has
  Erlang/OTP installed and by default does not require Elixir to
  be installed, as Elixir is embedded as part of the escript.

  This task guarantees the project and its dependencies are
  compiled and packages them inside an escript. Before invoking
  `mix escript.build`, it is only necessary to define a `:escript`
  key with a `:main_module` option in your `mix.exs` file:

      escript: [main_module: MyApp.CLI]

  Escripts should be used as a mechanism to share scripts between
  developers and not as a deployment mechanism. For running live
  systems, consider using `mix run` or building releases. See
  the `Application` module for more information on systems
  life cycles.

  All of the configuration defined in `config/config.exs` will
  be included as part of the escript. `config/runtime.exs` is also
  included for Elixir escripts. Once the configuration is loaded,
  this task starts the current application. If this is not desired,
  set the `:app` configuration to nil.

  This task also removes documentation and debugging chunks from
  the compiled `.beam` files to reduce the size of the escript.
  If this is not desired, check the `:strip_beams` option.

  ## Command line options

  Expects the same command line options as `mix compile`.

  ## Configuration

  The following option must be specified in your `mix.exs`
  under the `:escript` key:

    * `:main_module` - the module to be invoked once the escript starts.
      The module must contain a function named `main/1` that will receive the
      command line arguments. By default the arguments are given as a list of
      binaries, but if project is configured with `language: :erlang` it will
      be a list of charlists.

  The remaining options can be specified to further customize the escript:

    * `:name` - the name of the generated escript.
      Defaults to app name.

    * `:path` - the path to write the escript to.
      Defaults to app name.

    * `:app` - the app that starts with the escript.
      Defaults to app name. Set it to `nil` if no application should
      be started.

    * `:strip_beams` - if `true` strips BEAM code in the escript to remove chunks
      unnecessary at runtime, such as debug information and documentation.
      Can be set to `[keep: ["Docs", "Dbgi"]]` to strip while keeping some chunks
      that would otherwise be stripped, like docs, and debug info, for instance.
      Defaults to `true`.

    * `:embed_elixir` - if `true` embeds Elixir and its children apps
      (`ex_unit`, `mix`, and the like) mentioned in the `:applications` list inside the
      `application/0` function in `mix.exs`.

      Defaults to `true` for Elixir projects, `false` for Erlang projects.

      Note: if you set this to `false` for an Elixir project, you will have to add paths to Elixir's
      `ebin` directories to `ERL_LIBS` environment variable when running the resulting escript, in
      order for the code loader to be able to find `:elixir` application and its children
      applications (if they are used).

    * `:shebang` - shebang interpreter directive used to execute the escript.
      Defaults to `"#! /usr/bin/env escript\n"`.

    * `:comment` - comment line to follow shebang directive in the escript.
      Defaults to `""`.

    * `:emu_args` - emulator arguments to embed in the escript file.
      Defaults to `""`.

    * `:include_priv_for` - a list of application names (atoms) specifying
      applications which priv directory should be included in the resulting
      escript archive. Currently the expected way of accessing priv files
      in an escript is via `:escript.extract/2`. Defaults to `[]`.

  There is one project-level option that affects how the escript is generated:

    * `language: :elixir | :erlang` - set it to `:erlang` for Erlang projects
      managed by Mix. Doing so will ensure Elixir is not embedded by default.
      Your app will still be started as part of escript loading, with the
      config used during build.

  ## Example

  In your `mix.exs`:

      defmodule MyApp.MixProject do
        use Mix.Project

        def project do
          [
            app: :my_app,
            version: "0.0.1",
            escript: escript()
          ]
        end

        def escript do
          [main_module: MyApp.CLI]
        end
      end

  Then define the entrypoint, such as the following in `lib/cli.ex`:

      defmodule MyApp.CLI do
        def main(_args) do
          IO.puts("Hello from MyApp!")
        end
      end

  """

  @impl true
  def run(args) do
    Mix.Project.get!()
    Mix.Task.run("compile", args)

    project = Mix.Project.config()
    language = Keyword.get(project, :language, :elixir)
    escriptize(project, language)
  end

  defp escriptize(project, language) do
    escript_opts = project[:escript] || []
    script_name = Mix.Local.name_for(:escripts, project)
    filename = escript_opts[:path] || script_name
    main = escript_opts[:main_module]

    if !main do
      error_message =
        "Could not generate escript, please set :main_module " <>
          "in your project configuration (under :escript option) to a module that implements main/1"

      Mix.raise(error_message)
    end

    if not Code.ensure_loaded?(main) do
      error_message =
        "Could not generate escript, module #{main} defined as " <>
          ":main_module could not be loaded"

      Mix.raise(error_message)
    end

    app = Keyword.get(escript_opts, :app, project[:app])

    # Need to keep :strip_beam option for backward compatibility so
    # check for correct :strip_beams, then :strip_beam, then
    # use default true if neither are present.
    strip_options =
      escript_opts
      |> Keyword.get_lazy(:strip_beams, fn ->
        if Keyword.get(escript_opts, :strip_beam, true) do
          true
        else
          IO.warn(
            ":strip_beam option in escript.build is deprecated. Please use :strip_beams instead"
          )

          false
        end
      end)
      |> parse_strip_beams_options()

    escript_mod = String.to_atom(Atom.to_string(app) <> "_escript")

    include_priv_for = MapSet.new(escript_opts[:include_priv_for] || [])

    beam_paths =
      [
        project_files(project, include_priv_for),
        deps_files(include_priv_for),
        core_files(escript_opts, language, include_priv_for)
      ]
      |> Stream.concat()
      |> replace_consolidated_paths(project)

    tuples = gen_main(project, escript_mod, main, app, language) ++ read_beams(beam_paths)
    tuples = if strip_options, do: strip_beams(tuples, strip_options), else: tuples

    case :zip.create(~c"mem", tuples, [:memory]) do
      {:ok, {~c"mem", zip}} ->
        shebang = escript_opts[:shebang] || "#! /usr/bin/env escript\n"
        comment = build_comment(escript_opts[:comment])
        emu_args = build_emu_args(escript_opts[:emu_args], escript_mod)

        script = IO.iodata_to_binary([shebang, comment, emu_args, zip])
        File.mkdir_p!(Path.dirname(filename))
        File.write!(filename, script)
        set_perms(filename)

      {:error, error} ->
        Mix.raise("Error creating escript: #{error}")
    end

    Mix.shell().info("Generated escript #{filename} with MIX_ENV=#{Mix.env()}")
    :ok
  end

  defp project_files(project, include_priv_for) do
    get_files(Mix.Project.app_path(), project[:app] in include_priv_for)
  end

  defp get_files(app_path, include_priv?) do
    paths = Path.wildcard("#{app_path}/ebin/*.{app,beam}")

    paths =
      if include_priv? do
        paths ++ (Path.wildcard("#{app_path}/priv/**/*") |> Enum.filter(&File.regular?/1))
      else
        paths
      end

    apps_dir = Path.dirname(app_path)

    for path <- paths do
      {Path.relative_to(path, apps_dir), path}
    end
  end

  defp set_perms(filename) do
    stat = File.stat!(filename)
    :ok = File.chmod(filename, stat.mode ||| 0o111)
  end

  defp deps_files(include_priv_for) do
    deps = Mix.Dep.cached()
    Enum.flat_map(deps, fn dep -> get_files(dep.opts[:build], dep.app in include_priv_for) end)
  end

  defp core_files(escript_opts, language, include_priv_for) do
    if Keyword.get(escript_opts, :embed_elixir, language == :elixir) do
      Enum.flat_map([:elixir | extra_apps()], &app_files(&1, include_priv_for))
    else
      []
    end
  end

  defp extra_apps() do
    Mix.Project.config()[:app]
    |> extra_apps_in_app_tree()
    |> Enum.uniq()
  end

  defp extra_apps_in_app_tree(app) when app in [:kernel, :stdlib, :elixir] do
    []
  end

  defp extra_apps_in_app_tree(app) when app in [:eex, :ex_unit, :iex, :logger, :mix] do
    [app]
  end

  defp extra_apps_in_app_tree(app) do
    _ = Application.load(app)

    case Application.spec(app) do
      nil ->
        []

      spec ->
        applications =
          Keyword.get(spec, :applications, []) ++ Keyword.get(spec, :included_applications, [])

        Enum.flat_map(applications, &extra_apps_in_app_tree/1)
    end
  end

  defp app_files(app, include_priv_for) do
    case :code.where_is_file(~c"#{app}.app") do
      :non_existing -> Mix.raise("Could not find application #{app}")
      file -> get_files(Path.dirname(Path.dirname(file)), app in include_priv_for)
    end
  end

  defp read_beams(items) do
    Enum.map(items, fn {basename, beam_path} ->
      {String.to_charlist(basename), File.read!(beam_path)}
    end)
  end

  defp parse_strip_beams_options(options) do
    case options do
      options when is_list(options) -> options
      true -> []
      false -> nil
    end
  end

  defp strip_beams(tuples, strip_options) do
    for {basename, maybe_beam} <- tuples do
      with ".beam" <- Path.extname(basename),
           {:ok, binary} <- Mix.Release.strip_beam(maybe_beam, strip_options) do
        {basename, binary}
      else
        _ -> {basename, maybe_beam}
      end
    end
  end

  defp replace_consolidated_paths(files, config) do
    # We could write modules to a consolidated/ directory and prepend
    # it to code path using VM args. However, when Erlang Escript
    # boots, it prepends all second-level ebin/ directories to the
    # path, so the unconsolidated modules would take precedence.
    #
    # Instead of writing consolidated/ into the archive, we replace
    # the protocol modules with their consolidated version in their
    # usual location. As a side benefit, this reduces the Escript
    # file size, since we do not include the unconsolidated modules.

    if config[:consolidate_protocols] do
      consolidation_path = Mix.Project.consolidation_path(config)

      consolidated =
        consolidation_path
        |> Path.join("*")
        |> Path.wildcard()
        |> Map.new(fn path -> {Path.basename(path), path} end)

      for {zip_path, path} <- files do
        {zip_path, consolidated[Path.basename(path)] || path}
      end
    else
      files
    end
  end

  defp build_comment(user_comment) do
    "%% #{user_comment}\n"
  end

  defp build_emu_args(user_args, escript_mod) do
    "%%! -escript main #{escript_mod} #{user_args}\n"
  end

  defp gen_main(project, name, module, app, language) do
    config_path = project[:config_path]

    compile_config =
      if File.regular?(config_path) do
        config = Config.Reader.read!(config_path, env: Mix.env(), target: Mix.target())
        Macro.escape(config)
      else
        []
      end

    runtime_path = config_path |> Path.dirname() |> Path.join("runtime.exs")

    runtime_config =
      if File.regular?(runtime_path) do
        File.read!(runtime_path)
      end

    module_body =
      quote do
        @spec main(OptionParser.argv()) :: any
        def main(args) do
          unquote(main_body_for(language, module, compile_config, runtime_config))
        end

        defp load_config(config) do
          each_fun = fn {app, kw} ->
            set_env_fun = fn {k, v} -> :application.set_env(app, k, v, persistent: true) end
            :lists.foreach(set_env_fun, kw)
          end

          :lists.foreach(each_fun, config)
          :ok
        end

        defp start_app() do
          unquote(start_app_for(app))
        end

        defp io_error(message) do
          :io.put_chars(:standard_error, message)
        end
      end

    {:module, ^name, binary, _} = Module.create(name, module_body, Macro.Env.location(__ENV__))
    [{~c"#{name}.beam", binary}]
  end

  defp main_body_for(:elixir, module, compile_config, runtime_config) do
    config =
      if runtime_config do
        quote do
          runtime_config =
            Config.Reader.eval!(
              "config/runtime.exs",
              unquote(runtime_config),
              env: unquote(Mix.env()),
              target: unquote(Mix.target()),
              imports: :disabled
            )

          Config.Reader.merge(unquote(compile_config), runtime_config)
        end
      else
        compile_config
      end

    quote do
      case :application.ensure_all_started(:elixir) do
        {:ok, _} ->
          args = Enum.map(args, &List.to_string(&1))
          System.argv(args)
          load_config(unquote(config))
          start_app()
          Kernel.CLI.run(fn _ -> unquote(module).main(args) end)

        error ->
          io_error(["ERROR! Failed to start Elixir.\n", :io_lib.format(~c"error: ~p~n", [error])])
          :erlang.halt(1)
      end
    end
  end

  defp main_body_for(:erlang, module, compile_config, _runtime_config) do
    quote do
      load_config(unquote(compile_config))
      start_app()
      unquote(module).main(args)
    end
  end

  defp start_app_for(nil) do
    :ok
  end

  defp start_app_for(app) do
    quote do
      case :application.ensure_all_started(unquote(app)) do
        {:ok, _} ->
          :ok

        {:error, {app, reason}} ->
          formatted_error =
            case :code.ensure_loaded(Application) do
              {:module, Application} -> Application.format_error(reason)
              {:error, _} -> :io_lib.format(~c"~p", [reason])
            end

          error_message = [
            "ERROR! Could not start application ",
            :erlang.atom_to_binary(app, :utf8),
            ": ",
            formatted_error,
            ?\n
          ]

          io_error(error_message)
          :erlang.halt(1)
      end
    end
  end
end
