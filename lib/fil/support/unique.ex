defmodule Fil.Support.Unique do
  @moduledoc false

  # Unique names for temporary files and directories. The counter and the time make a name unique on this node, also
  # across restarts. The random part makes it unique across nodes that share a directory, and hard to guess, so nobody
  # can create a temporary directory's name before `Fil.tmp/0,1` does.

  @doc "A unique name, such as `\"4-SJ2LQPBW3X-NT5WMZLF\"`."
  @spec name() :: String.t()
  def name do
    counter =
      [:positive]
      |> System.unique_integer()
      |> Integer.to_string(36)

    time =
      :microsecond
      |> System.system_time()
      |> Integer.to_string(36)

    random =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode32(padding: false)

    Enum.join([counter, time, random], "-")
  end
end
