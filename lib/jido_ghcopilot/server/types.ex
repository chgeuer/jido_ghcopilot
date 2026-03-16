defmodule Jido.GHCopilot.Server.Types do
  @moduledoc """
  Type definitions for the CLI Server protocol JSON-RPC messages.

  The CLI Server protocol is activated via `copilot --server --stdio` and uses
  JSON-RPC 2.0 over stdio. Unlike ACP's curated `session/update` notifications,
  the CLI Server forwards **all** raw session events via `session.event`
  notifications — including `assistant.usage` with token counts, cost, and
  quota data.
  """

  defmodule UsageEvent do
    @moduledoc "Token usage data from an `assistant.usage` session event."
    defstruct [
      :model,
      :input_tokens,
      :output_tokens,
      :cache_read_tokens,
      :cache_write_tokens,
      :cost,
      :duration_ms,
      :initiator,
      :api_call_id,
      :provider_call_id,
      :quota_snapshots
    ]

    @type t :: %__MODULE__{
            model: String.t() | nil,
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            cache_read_tokens: non_neg_integer(),
            cache_write_tokens: non_neg_integer(),
            cost: number() | nil,
            duration_ms: number() | nil,
            initiator: String.t() | nil,
            api_call_id: String.t() | nil,
            provider_call_id: String.t() | nil,
            quota_snapshots: map() | nil
          }
  end

  defmodule SessionEvent do
    @moduledoc """
    A raw session event delivered via `session.event` notification.

    The `type` field determines the event category:
    - `"assistant.usage"` — token/cost metrics (ephemeral)
    - `"assistant.message"` — model output text
    - `"assistant.turn_start"` / `"assistant.turn_end"` — turn boundaries
    - `"assistant.intent"` — thinking/reasoning
    - `"tool.execution_start"` / `"tool.execution_complete"` — tool calls
    - `"session.start"` / `"session.idle"` / `"session.error"` — lifecycle
    - etc. (27+ event types)
    """
    defstruct [
      :id,
      :type,
      :data,
      :timestamp,
      :parent_id,
      :session_id,
      ephemeral: false
    ]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            type: String.t(),
            data: map(),
            timestamp: String.t() | nil,
            parent_id: String.t() | nil,
            session_id: String.t(),
            ephemeral: boolean()
          }
  end

  defmodule Attachment do
    @moduledoc """
    A file or directory attachment for `session.send`.

    The Copilot CLI converts attachments into `<tagged_files>` context
    that is injected into the prompt, allowing the model to see file
    metadata without the user manually pasting content.
    """
    defstruct [:type, :path, :display_name]

    @type attachment_type :: :file | :directory
    @type t :: %__MODULE__{
            type: attachment_type(),
            path: String.t(),
            display_name: String.t()
          }

    @doc "Create a file attachment from an absolute path."
    def file(path, display_name \\ nil) do
      %__MODULE__{
        type: :file,
        path: Path.expand(path),
        display_name: display_name || Path.basename(path)
      }
    end

    @doc "Create a directory attachment from an absolute path."
    def directory(path, display_name \\ nil) do
      %__MODULE__{
        type: :directory,
        path: Path.expand(path),
        display_name: display_name || Path.basename(path)
      }
    end

    @doc "Convert to the JSON-encodable map expected by the Copilot CLI."
    def to_json(%__MODULE__{type: type, path: path, display_name: display_name}) do
      %{type: to_string(type), path: path, displayName: display_name}
    end
  end

  defmodule CreateResult do
    @moduledoc "Result of `session.create`."
    defstruct [:session_id]
    @type t :: %__MODULE__{session_id: String.t()}
  end

  defmodule SendResult do
    @moduledoc "Result of `session.send`."
    defstruct [:message_id]
    @type t :: %__MODULE__{message_id: String.t()}
  end

  defmodule ListEntry do
    @moduledoc "A session entry from `session.list`."
    defstruct [:session_id, :start_time, :modified_time, :summary, :is_remote]

    @type t :: %__MODULE__{
            session_id: String.t(),
            start_time: String.t(),
            modified_time: String.t(),
            summary: String.t() | nil,
            is_remote: boolean()
          }
  end
end
