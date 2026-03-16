defmodule Jido.GHCopilot.ACP.Types do
  @moduledoc """
  Type definitions for the Agent Client Protocol (ACP) JSON-RPC messages.

  ACP is a JSON-RPC 2.0 protocol over stdio/TCP that standardizes communication
  between clients and coding agents. These types model the Copilot CLI's ACP
  server responses and notifications.
  """

  # ── Initialization ──

  defmodule InitResult do
    @moduledoc "Result of `initialize` handshake."
    defstruct [
      :protocol_version,
      :agent_info,
      :agent_capabilities,
      :auth_methods
    ]

    @type t :: %__MODULE__{
            protocol_version: integer(),
            agent_info: Jido.GHCopilot.ACP.Types.AgentInfo.t() | nil,
            agent_capabilities: Jido.GHCopilot.ACP.Types.AgentCapabilities.t() | nil,
            auth_methods: [map()] | nil
          }
  end

  defmodule AgentInfo do
    @moduledoc "Agent identity metadata."
    defstruct [:name, :title, :version]

    @type t :: %__MODULE__{
            name: String.t(),
            title: String.t(),
            version: String.t()
          }
  end

  defmodule AgentCapabilities do
    @moduledoc "Capabilities declared by the agent during initialization."
    defstruct load_session: false,
              prompt_capabilities: nil,
              session_capabilities: nil,
              mcp_capabilities: nil

    @type t :: %__MODULE__{
            load_session: boolean(),
            prompt_capabilities: map() | nil,
            session_capabilities: map() | nil,
            mcp_capabilities: map() | nil
          }
  end

  # ── Session ──

  defmodule SessionResult do
    @moduledoc "Result of `session/new` — contains the session ID."
    defstruct [:session_id]
    @type t :: %__MODULE__{session_id: String.t()}
  end

  # ── Prompt ──

  defmodule PromptResult do
    @moduledoc "Result of `session/prompt` — indicates why the turn ended."
    defstruct [:stop_reason]

    @type stop_reason ::
            :end_turn | :max_tokens | :max_turn_requests | :refusal | :cancelled

    @type t :: %__MODULE__{stop_reason: stop_reason()}
  end

  defmodule ContentBlock do
    @moduledoc "A content block in a prompt or response (text, resource, image)."
    defstruct [:type, :text, :resource]

    @type t :: %__MODULE__{
            type: String.t(),
            text: String.t() | nil,
            resource: map() | nil
          }
  end

  # ── Session Updates (notifications from agent) ──

  defmodule SessionUpdate do
    @moduledoc """
    A `session/update` notification from the agent.

    The `update_type` field determines the shape of `data`:
    - `"agent_message_chunk"` — text content from the model
    - `"agent_thought_chunk"` — thinking/reasoning content
    - `"tool_call"` — tool invocation started
    - `"tool_call_update"` — tool status change (in_progress, completed, etc.)
    - `"plan"` — agent's structured plan
    - `"user_message_chunk"` — replayed user message (session/load)
    """
    defstruct [:session_id, :update_type, :data]

    @type update_type ::
            :agent_message_chunk
            | :agent_thought_chunk
            | :tool_call
            | :tool_call_update
            | :plan
            | :user_message_chunk
            | :unknown

    @type t :: %__MODULE__{
            session_id: String.t(),
            update_type: update_type(),
            data: map()
          }
  end

  defmodule ToolCall do
    @moduledoc "A tool call reported by the agent."
    defstruct [:tool_call_id, :title, :kind, :status, :content]

    @type status :: :pending | :in_progress | :completed | :cancelled | :failed
    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            title: String.t() | nil,
            kind: String.t() | nil,
            status: status(),
            content: [map()] | nil
          }
  end

  defmodule PlanEntry do
    @moduledoc "A single entry in the agent's plan."
    defstruct [:content, :priority, :status]

    @type t :: %__MODULE__{
            content: String.t(),
            priority: String.t() | nil,
            status: String.t() | nil
          }
  end

  # ── Permission Request (agent → client) ──

  defmodule PermissionRequest do
    @moduledoc "A `session/request_permission` request from the agent."
    defstruct [:session_id, :tool_call_id, :tool_name, :input]

    @type t :: %__MODULE__{
            session_id: String.t(),
            tool_call_id: String.t() | nil,
            tool_name: String.t() | nil,
            input: map() | nil
          }
  end

  # ── JSON-RPC envelope ──

  defmodule Request do
    @moduledoc "A JSON-RPC 2.0 request."
    defstruct [:id, :method, :params]

    @type t :: %__MODULE__{
            id: integer(),
            method: String.t(),
            params: map()
          }
  end

  defmodule Response do
    @moduledoc "A JSON-RPC 2.0 response (success or error)."
    defstruct [:id, :result, :error]

    @type t :: %__MODULE__{
            id: integer(),
            result: map() | nil,
            error: map() | nil
          }
  end

  defmodule Notification do
    @moduledoc "A JSON-RPC 2.0 notification (no id, no response expected)."
    defstruct [:method, :params]

    @type t :: %__MODULE__{
            method: String.t(),
            params: map()
          }
  end
end
