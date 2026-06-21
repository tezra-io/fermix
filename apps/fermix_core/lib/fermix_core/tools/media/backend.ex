defmodule FermixCore.Tools.Media.Backend do
  @moduledoc """
  Behaviour for a single media-generation vendor backend (one backend = one
  modality). Mirrors `FermixCore.Tools.WebSearch.Backend`, extended for
  operations (`:generate` / `:edit`) and an async submit/poll path.

  The sync `run/3` path covers image (and the future audio modality). The async
  `submit/2` + `poll/2` path is implemented only by video backends and is
  `@optional_callbacks`; the tool never calls it unless `capabilities().async`
  is true, so a sync backend simply omits it. The dispatch is chosen by the
  declared `capabilities().async` fact, never by a runtime try/fallback.
  """

  @type modality :: :image | :audio | :video
  @type operation :: :generate | :edit

  @typedoc "A produced artifact: bytes already in hand, ready for egress."
  @type artifact :: %{bytes: binary(), mime: String.t(), ext: String.t()}

  @typedoc "A submitted async job the tool must poll (video only)."
  @type job :: %{provider_op: String.t(), poll_token: term(), submitted_at: integer()}

  @type trace :: %{optional(atom()) => term()}
  @type opts :: keyword()

  @type capabilities :: %{
          ops: [operation()],
          mask: boolean(),
          multi_image_ref: boolean(),
          async: boolean()
        }

  @callback name() :: atom()
  @callback modality() :: modality()
  @callback configured?(opts()) :: boolean()

  @doc """
  Curated model ids this backend supports, head = the default. Ships in code (the
  `ModelCatalog` rule — never fetched from a provider API at setup); the setup
  surface renders these as the model dropdown and the run path defaults to the head.
  """
  @callback supported_models() :: [String.t(), ...]

  @doc "The capability gate. Which ops/sub-features this backend honors, and whether it is async."
  @callback capabilities() :: capabilities()

  @doc "Sync path (image; future audio). One call returns bytes."
  @callback run(operation(), request :: map(), opts()) ::
              {:ok, artifact(), trace()} | {:error, String.t(), trace()}

  @doc "Async submit (video only). Returns a job to poll."
  @callback submit(request :: map(), opts()) ::
              {:ok, job(), trace()} | {:error, String.t(), trace()}

  @doc "Async poll (video only). MUST download bytes to own storage on `:ok` (provider URLs expire)."
  @callback poll(job(), opts()) ::
              {:pending, trace()} | {:ok, artifact(), trace()} | {:error, String.t(), trace()}

  @optional_callbacks submit: 2, poll: 2
end
