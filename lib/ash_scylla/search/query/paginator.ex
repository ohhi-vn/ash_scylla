defmodule AshScylla.Search.Query.Paginator do
  @moduledoc """
  Pagination helpers for search results.
  """

  @type page :: %{
    entries: [entry()],
    page_number: pos_integer(),
    page_size: pos_integer(),
    total_count: non_neg_integer(),
    total_pages: non_neg_integer(),
    has_next?: boolean(),
    has_prev?: boolean()
  }

  @type entry :: {String.t(), float()}

  @doc """
  Paginates a list of results.

  ## Options
    * `:page` — page number, starting at 1 (default: `1`)
    * `:page_size` — number of results per page (default: `20`)

  Returns a map with metadata about the current page.
  """
  @spec paginate([entry()], keyword()) :: {:ok, page()} | {:error, term()}
  def paginate(results, opts \\ []) do
    page_number = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 20)

    if page_number < 1 or page_size < 1 do
      {:error, :invalid_pagination_params}
    else
      total_count = length(results)
      total_pages = max(1, ceil(total_count / page_size))

      page_number =
        if page_number > total_pages do
          total_pages
        else
          page_number
        end

      offset = (page_number - 1) * page_size
      entries = results |> Enum.drop(offset) |> Enum.take(page_size)

      {:ok,
       %{
         entries: entries,
         page_number: page_number,
         page_size: page_size,
         total_count: total_count,
         total_pages: total_pages,
         has_next?: page_number < total_pages,
         has_prev?: page_number > 1
       }}
    end
  end
end
