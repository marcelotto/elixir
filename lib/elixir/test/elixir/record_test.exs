# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

Code.require_file("test_helper.exs", __DIR__)

defmodule RecordTest do
  use ExUnit.Case, async: true

  require Record
  doctest Record

  test "extract/2 extracts information from an Erlang file" do
    assert Record.extract(:file_info, from_lib: "kernel/include/file.hrl") == [
             size: :undefined,
             type: :undefined,
             access: :undefined,
             atime: :undefined,
             mtime: :undefined,
             ctime: :undefined,
             mode: :undefined,
             links: :undefined,
             major_device: :undefined,
             minor_device: :undefined,
             inode: :undefined,
             uid: :undefined,
             gid: :undefined
           ]
  end

  test "extract/2 handles nested records too" do
    namespace = Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")[:namespace]
    assert is_tuple(namespace)
    assert elem(namespace, 0) == :xmlNamespace
  end

  test "extract/2 with defstruct" do
    defmodule StructExtract do
      defstruct Record.extract(:file_info, from_lib: "kernel/include/file.hrl")
    end

    assert %{__struct__: StructExtract, size: :undefined} = StructExtract.__struct__()
  end

  test "extract_all/1 extracts all records information from an Erlang file" do
    all_extract = Record.extract_all(from_lib: "kernel/include/file.hrl")
    # has been stable over the very long time
    assert length(all_extract) == 2
    assert all_extract[:file_info]
    assert all_extract[:file_descriptor]
  end

  # We need indirection to avoid warnings
  defp record?(data, kind) do
    Record.is_record(data, kind)
  end

  test "is_record/2" do
    assert record?({User, "meg", 27}, User)
    refute record?({User, "meg", 27}, Author)
    refute record?(13, Author)
    refute record?({"user", "meg", 27}, "user")
    refute record?({}, User)
    refute record?([], User)
  end

  # We need indirection to avoid warnings
  defp record?(data) do
    Record.is_record(data)
  end

  test "is_record/1" do
    assert record?({User, "john", 27})
    refute record?({"john", 27})
    refute record?(13)
    refute record?({})
  end

  def record_in_guard?(term) when Record.is_record(term), do: true
  def record_in_guard?(_), do: false

  def record_in_guard?(term, kind) when Record.is_record(term, kind), do: true
  def record_in_guard?(_, _), do: false

  test "is_record/1,2 (in guard)" do
    assert record_in_guard?({User, "john", 27})
    refute record_in_guard?({"user", "john", 27})

    assert record_in_guard?({User, "john", 27}, User)
    refute record_in_guard?({"user", "john", 27}, "user")
  end

  Record.defrecord(:timestamp, [:date, :time])
  Record.defrecord(:user, __MODULE__, name: "john", age: 25)

  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  Record.defrecordp(
    :certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  test "records are tagged" do
    assert elem(file_info(), 0) == :file_info
  end

  test "records macros" do
    record = user()
    assert user(record, :name) == "john"
    assert user(record, :age) == 25

    record = user(record, name: "meg")
    assert user(record, :name) == "meg"

    assert elem(record, user(:name)) == "meg"
    assert elem(record, 0) == RecordTest

    user(name: name) = record
    assert name == "meg"

    assert user(:name) == 1
  end

  test "records with default values" do
    record = user(_: :_, name: "meg")
    assert user(record, :name) == "meg"
    assert user(record, :age) == :_
    assert match?(user(_: _), user())
  end

  test "records preserve side-effects order" do
    user =
      user(
        age: send(self(), :age),
        name: send(self(), :name)
      )

    assert Process.info(self(), :messages) == {:messages, [:age, :name]}

    _ =
      user(user,
        age: send(self(), :update_age),
        name: send(self(), :update_name)
      )

    assert Process.info(self(), :messages) ==
             {:messages, [:age, :name, :update_age, :update_name]}
  end

  test "nested records preserve side-effects order" do
    user =
      user(
        age:
          user(
            age: send(self(), :inner_age),
            name: send(self(), :inner_name)
          ),
        name: send(self(), :name)
      )

    assert user == {RecordTest, :name, {RecordTest, :inner_name, :inner_age}}
    assert for(_ <- 1..3, do: assert_receive(_)) == [:inner_age, :inner_name, :name]

    user =
      user(
        name: send(self(), :name),
        age:
          user(
            age: send(self(), :inner_age),
            name: send(self(), :inner_name)
          )
      )

    assert user == {RecordTest, :name, {RecordTest, :inner_name, :inner_age}}
    assert for(_ <- 1..3, do: assert_receive(_)) == [:name, :inner_age, :inner_name]
  end

  Record.defrecord(
    :defaults,
    struct: ~D[2016-01-01],
    map: %{},
    tuple_zero: {},
    tuple_one: {1},
    tuple_two: {1, 2},
    tuple_three: {1, 2, 3},
    list: [1, 2, 3],
    call: MapSet.new(),
    string: "abc",
    binary: <<1, 2, 3>>,
    charlist: ~c"abc"
  )

  test "records with literal defaults and on-the-fly record" do
    assert defaults(defaults()) == [
             struct: ~D[2016-01-01],
             map: %{},
             tuple_zero: {},
             tuple_one: {1},
             tuple_two: {1, 2},
             tuple_three: {1, 2, 3},
             list: [1, 2, 3],
             call: MapSet.new(),
             string: "abc",
             binary: <<1, 2, 3>>,
             charlist: ~c"abc"
           ]

    assert defaults(defaults(), :struct) == ~D[2016-01-01]
    assert defaults(defaults(), :map) == %{}
    assert defaults(defaults(), :tuple_zero) == {}
    assert defaults(defaults(), :tuple_one) == {1}
    assert defaults(defaults(), :tuple_two) == {1, 2}
    assert defaults(defaults(), :tuple_three) == {1, 2, 3}
    assert defaults(defaults(), :list) == [1, 2, 3]
    assert defaults(defaults(), :call) == MapSet.new()
    assert defaults(defaults(), :string) == "abc"
    assert defaults(defaults(), :binary) == <<1, 2, 3>>
    assert defaults(defaults(), :charlist) == ~c"abc"
  end

  test "records with literal defaults and record in a variable" do
    defaults = defaults()

    assert defaults(defaults) == [
             struct: ~D[2016-01-01],
             map: %{},
             tuple_zero: {},
             tuple_one: {1},
             tuple_two: {1, 2},
             tuple_three: {1, 2, 3},
             list: [1, 2, 3],
             call: MapSet.new(),
             string: "abc",
             binary: <<1, 2, 3>>,
             charlist: ~c"abc"
           ]

    assert defaults(defaults, :struct) == ~D[2016-01-01]
    assert defaults(defaults, :map) == %{}
    assert defaults(defaults, :tuple_zero) == {}
    assert defaults(defaults, :tuple_one) == {1}
    assert defaults(defaults, :tuple_two) == {1, 2}
    assert defaults(defaults, :tuple_three) == {1, 2, 3}
    assert defaults(defaults, :list) == [1, 2, 3]
    assert defaults(defaults, :call) == MapSet.new()
    assert defaults(defaults, :string) == "abc"
    assert defaults(defaults, :binary) == <<1, 2, 3>>
    assert defaults(defaults, :charlist) == ~c"abc"
  end

  test "records with dynamic arguments" do
    record = file_info()
    assert file_info(record, :size) == :undefined

    record = user()
    assert user(record) == [name: "john", age: 25]
    assert user(user()) == [name: "john", age: 25]

    msg =
      "expected argument to be a literal atom, literal keyword or a :file_info record, " <>
        "got runtime: {RecordTest, \"john\", 25}"

    assert_raise ArgumentError, msg, fn ->
      file_info(record)
    end

    pretender = {RecordTest, "john"}

    msg =
      "expected argument to be a RecordTest record with 2 fields, " <>
        "got: {RecordTest, \"john\"}"

    assert_raise ArgumentError, msg, fn ->
      user(pretender)
    end

    pretender = {RecordTest, "john", 25, []}

    msg =
      "expected argument to be a RecordTest record with 2 fields, " <>
        "got: {RecordTest, \"john\", 25, []}"

    assert_raise ArgumentError, msg, fn ->
      user(pretender)
    end
  end

  test "records visibility" do
    assert macro_exported?(__MODULE__, :user, 0)
    refute macro_exported?(__MODULE__, :file_info, 1)
  end

  test "records reflection" do
    assert %{fields: [:name, :age], kind: :defrecord, name: :user, tag: RecordTest} in @__records__

    assert %{fields: [:date, :time], kind: :defrecord, name: :timestamp, tag: :timestamp} in @__records__
  end

  test "records with no defaults" do
    record = timestamp()
    assert timestamp(record, :date) == nil
    assert timestamp(record, :time) == nil

    record = timestamp(date: :foo, time: :bar)
    assert timestamp(record, :date) == :foo
    assert timestamp(record, :time) == :bar
  end

  test "records defined multiple times" do
    msg = "cannot define record :r because a definition r/0 already exists"

    assert_raise ArgumentError, msg, fn ->
      defmodule M do
        import Record
        defrecord :r, [:a]
        defrecord :r, [:a]
      end
    end
  end

  test "macro and record with the same name defined" do
    msg = "cannot define record :a because a definition a/1 already exists"

    assert_raise ArgumentError, msg, fn ->
      defmodule M do
        defmacro a(_) do
        end

        require Record
        Record.defrecord(:a, [:a])
      end
    end

    msg = "cannot define record :a because a definition a/2 already exists"

    assert_raise ArgumentError, msg, fn ->
      defmodule M do
        defmacro a(_, _) do
        end

        require Record
        Record.defrecord(:a, [:a])
      end
    end
  end

  test "docs metadata" do
    import PathHelpers

    write_beam(
      defmodule Metadata do
        Record.defrecord(:user, foo: 0, bar: "baz")
      end
    )

    {:docs_v1, 352, :elixir, "text/markdown", _, %{}, docs} = Code.fetch_docs(RecordTest.Metadata)
    {{:macro, :user, 1}, _meta, _sig, _docs, metadata} = List.keyfind(docs, {:macro, :user, 1}, 0)
    assert %{record: {:user, [foo: 0, bar: "baz"]}} = metadata
  end

  describe "warnings" do
    import ExUnit.CaptureIO

    test "warns on bad record update input" do
      assert capture_io(:stderr, fn ->
               defmodule RecordSample do
                 require Record
                 Record.defrecord(:user, __MODULE__, name: "john", age: 25)

                 def fun do
                   user(user(), _: :_, name: "meg")
                 end
               end
             end) =~
               "updating a record with a default (:_) is equivalent to creating a new record"
    after
      purge(RecordSample)
    end

    test "defrecord warns with duplicate keys" do
      assert capture_io(:stderr, fn ->
               Code.eval_string("""
               defmodule RecordSample do
                 import Record
                 defrecord :r, [:foo, :bar, foo: 1]
               end
               """)
             end) =~ "duplicate key :foo found in record"
    after
      purge(RecordSample)
    end

    defp purge(module) when is_atom(module) do
      :code.purge(module)
      :code.delete(module)
    end
  end
end
