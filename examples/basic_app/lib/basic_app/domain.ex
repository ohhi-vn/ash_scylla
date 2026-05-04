defmodule BasicApp.Domain do
  use Ash.Domain

  resources do
    resource BasicApp.Resources.User
    resource BasicApp.Resources.Post
    resource BasicApp.Resources.Comment
  end
end
