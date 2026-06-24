defmodule XMAVLink.Test.Message do
  use ExUnit.Case

  defmodule UnknownStruct do
    defstruct [:value]
  end

  test "invalid non-message terms return an explicit pack error" do
    assert {:error, message} = XMAVLink.Message.pack(:not_a_message, 2)
    assert message =~ "not a MAVLink message"
  end

  test "unknown message structs still raise Protocol.UndefinedError" do
    assert_raise Protocol.UndefinedError, fn ->
      XMAVLink.Message.pack(%UnknownStruct{}, 2)
    end
  end
end
