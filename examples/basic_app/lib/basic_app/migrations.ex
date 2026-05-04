defmodule BasicApp.Migrations do
  @moduledoc """
  Helper module to create database tables for the example application.
  """

  alias BasicApp.Repo

  @doc """
  Creates all tables needed for the example application.
  """
  def create_tables do
    # Create keyspace
    Repo.query("""
    CREATE KEYSPACE IF NOT EXISTS basic_app_dev
    WITH REPLICATION = {
      'class': 'SimpleStrategy',
      'replication_factor': 1
    }
    """)

    # Use the keyspace
    Repo.query("USE basic_app_dev")

    # Create users table
    Repo.query("""
    CREATE TABLE IF NOT EXISTS users (
      id UUID PRIMARY KEY,
      name TEXT,
      email TEXT,
      status TEXT,
      age INT,
      tags LIST<TEXT>,
      metadata MAP<TEXT, TEXT>,
      created_at TIMESTAMP
    )
    """)

    # Create secondary indexes for users
    Repo.query("CREATE INDEX IF NOT EXISTS idx_users_email ON users (email)")
    Repo.query("CREATE INDEX IF NOT EXISTS idx_users_status ON users (status)")

    # Create posts table with TTL
    Repo.query("""
    CREATE TABLE IF NOT EXISTS posts (
      id UUID PRIMARY KEY,
      title TEXT,
      content TEXT,
      status TEXT,
      author_id UUID,
      author_name TEXT,
      author_email TEXT,
      tags LIST<TEXT>,
      view_count INT,
      published_at TIMESTAMP,
      created_at TIMESTAMP
    ) WITH default_time_to_live = 2592000
    """)

    # Create secondary indexes for posts
    Repo.query("CREATE INDEX IF NOT EXISTS idx_posts_author_id ON posts (author_id)")
    Repo.query("CREATE INDEX IF NOT EXISTS idx_posts_status ON posts (status)")

    # Create comments table
    Repo.query("""
    CREATE TABLE IF NOT EXISTS comments (
      id UUID PRIMARY KEY,
      content TEXT,
      post_id UUID,
      author_id UUID,
      author_name TEXT,
      post_title TEXT,
      status TEXT,
      created_at TIMESTAMP
    )
    """)

    # Create composite secondary index for comments
    Repo.query(
      "CREATE INDEX IF NOT EXISTS idx_comments_post_id_status ON comments (post_id, status)"
    )

    :ok
  end

  @doc """
  Drops all tables and the keyspace.
  """
  def drop_tables do
    Repo.query("DROP KEYSPACE IF EXISTS basic_app_dev")
    :ok
  end
end
