defmodule XMAVLink.Test.Tasks do
  use ExUnit.Case

  import ExUnit.CaptureIO
  import Mix.Tasks.Xmavlink

  @input "#{File.cwd!()}/test/input/test_mavlink.xml"
  @output_dir "#{Mix.Project.build_path()}/generated"
  @output "#{@output_dir}/test_mavlink.ex"
  @output_module "TestMavlink"

  test "generate" do
    File.mkdir_p(@output_dir)
    File.rm(@output)

    output =
      capture_io(fn ->
        assert :ok = run([@input, @output, @output_module])
      end)

    assert output =~ "Generated #{@output_module}"
    assert File.exists?(@output)

    # We don't care if we redefine MAVLink modules while running the following test
    previous_compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    on_exit(fn ->
      Code.compiler_options(previous_compiler_options)
    end)

    # Confirm the list of modules generated from common.xml and its includes
    pairs =
      Enum.zip(
        [
          XMAVLink.Message.TestMavlink.Message.ChangeOperatorControl,
          XMAVLink.Message.TestMavlink.Message.Data16,
          XMAVLink.Message.TestMavlink.Message.Heartbeat,
          XMAVLink.Message.TestMavlink.Message.VfrHud,
          TestMavlink,
          TestMavlink.Message.ChangeOperatorControl,
          TestMavlink.Message.Data16,
          TestMavlink.Message.Heartbeat,
          TestMavlink.Message.VfrHud,
          TestMavlink.Types
        ]
        |> Enum.sort(),
        Code.compile_file(@output)
        |> Keyword.keys()
        |> Enum.sort()
      )

    for {expected, actual} <- pairs do
      assert expected == actual
    end
  end
end
