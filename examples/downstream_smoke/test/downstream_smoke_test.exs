defmodule XMAVLink.DownstreamSmokeTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias XMAVLink.Frame
  alias XMAVLink.Router

  test "consumer app can generate a dialect and use router subscribe/send flow" do
    repo_root = Path.expand("../../..", __DIR__)
    xml_path = Path.join(repo_root, "test/input/test_mavlink.xml")
    output_dir = Path.join(Mix.Project.build_path(), "generated")
    output_path = Path.join(output_dir, "downstream_smoke_dialect.ex")

    File.rm_rf!(output_dir)
    File.mkdir_p!(output_dir)

    capture_io(fn ->
      assert :ok = Mix.Tasks.Xmavlink.run([xml_path, output_path, "DownstreamSmoke.Dialect"])
    end)

    modules =
      output_path
      |> Code.compile_file()
      |> Keyword.keys()

    assert DownstreamSmoke.Dialect in modules
    assert DownstreamSmoke.Dialect.Message.Heartbeat in modules

    {:ok, router} =
      Router.start_link(
        %{
          name: nil,
          system: 245,
          component: 250,
          dialect: DownstreamSmoke.Dialect,
          connection_strings: []
        },
        []
      )

    on_exit(fn ->
      File.rm_rf!(output_dir)
      if Process.alive?(router), do: GenServer.stop(router)
    end)

    assert :ok =
             Router.subscribe(router,
               message: DownstreamSmoke.Dialect.Message.Heartbeat,
               as_frame: true
             )

    message = struct(DownstreamSmoke.Dialect.Message.Heartbeat, type: :mav_type_generic)

    assert :ok = Router.pack_and_send(router, message, 2)

    assert_receive %Frame{
                     version: 2,
                     source_system: 245,
                     source_component: 250,
                     message: ^message
                   },
                   200
  end
end
