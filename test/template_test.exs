defmodule LiveSidestep.TemplateTest.Fixture do
  import LiveSidestep.View, only: [sigil_V: 2]

  def counter(assigns) do
    ~V"""
    <column gap={@gap}>
      <text>Count: {@count}</text>
      <button phx-click="increment" phx-value-step={@step} incarnation={@incarnation}>Add {@step}</button>
      <input id="entry" value={@value} edit_revision={@revision} placeholder="Type here" phx-change="edit" />
    </column>
    """
  end

  def groups(assigns) do
    ~V"""
    <list id="groups">
      <column :for={group <- @groups} id={group.id}>
        <text>{group.label}</text>
        <row :for={item <- group.items} :if={item.visible} id={item.id}>
          <text>{item.name}</text>
          <input value={item.name} incarnation={item.incarnation} />
        </row>
      </column>
    </list>
    """
  end

  def conditional(assigns) do
    ~V"""
    <column>
      <text :if={@visible} id="optional">{Map.fetch!(@data, :label)}</text>
      <input id="always" value={@value} />
    </column>
    """
  end

  def expressions(assigns) do
    ~V"""
    <text>{Map.fetch!(%{"}" => @value}, "}")} {String.upcase("{ok}")} {~s|{sigil}|} {false} {nil}</text>
    """
  end

  def inline_calls(assigns) do
    ~V"""
    <text>{if @visible, do: "shown", else: "hidden"} {String.replace @value, "a", "b"}</text>
    """
  end

  def generator_pattern(assigns) do
    ~V"""
    <row><text :for={{id, value} <- @pairs} id={id}>{value}</text></row>
    """
  end
end

defmodule LiveSidestep.TemplateTest do
  use ExUnit.Case, async: true

  alias LiveSidestep.{Node, Template, Tree, UI}
  alias LiveSidestep.TemplateTest.Fixture

  test "native templates and constructors produce the same declaration and wire tree" do
    assigns = %{gap: 8, count: 12, step: 2, value: "hello", revision: 4, incarnation: 9}
    rendered = Fixture.counter(assigns)

    expected =
      UI.column(
        [
          UI.text("Count: 12"),
          Node.new!(
            "button",
            %{"phx-click" => "increment", "phx-value-step" => 2, "incarnation" => 9},
            ["Add 2"]
          ),
          UI.input("entry", "hello", edit_revision: 4, placeholder: "Type here", event: "edit")
        ],
        id: "root",
        gap: 8
      )

    assert rendered == expected
    assert Tree.flatten(rendered) == Tree.flatten(expected)
    assert Enum.all?(rendered.children, &(&1.children == []))
  end

  test "nested keyed loops scope static descendants under their application keys" do
    first = %{
      id: "group-a",
      label: "A",
      items: [
        %{id: "a-one", name: "one", visible: true, incarnation: 1},
        %{id: "a-hidden", name: "hidden", visible: false, incarnation: 1},
        %{id: "a-two", name: "two", visible: true, incarnation: 2}
      ]
    }

    second = %{
      id: "group-b",
      label: "B",
      items: [%{id: "b-one", name: "three", visible: true, incarnation: 1}]
    }

    before = Fixture.groups(%{groups: [first, second]}) |> Tree.flatten()

    after_tree =
      Fixture.groups(%{groups: [second, %{first | items: Enum.reverse(first.items)}]})
      |> Tree.flatten()

    assert before["nodes"]["groups"]["children"] == ["group-a", "group-b"]
    assert after_tree["nodes"]["groups"]["children"] == ["group-b", "group-a"]
    assert before["nodes"]["group-a"]["children"] == ["group-a/0", "a-one", "a-two"]
    assert after_tree["nodes"]["group-a"]["children"] == ["group-a/0", "a-two", "a-one"]
    assert before["nodes"]["a-one"]["children"] == ["a-one/0", "a-one/1"]
    assert after_tree["nodes"]["a-one/1"] == before["nodes"]["a-one/1"]
    assert after_tree["nodes"]["a-two/1"] == before["nodes"]["a-two/1"]
    refute Map.has_key?(before["nodes"], "a-hidden")

    patch = Tree.patch(before, after_tree, 1, 1)
    assert Enum.map(patch["upsert"], & &1["id"]) == ["group-a", "groups"]
    assert patch["remove"] == []
    assert Fixture.groups(%{groups: []}).children == []
  end

  test "conditional children are omitted without evaluating their content and can be inserted or removed" do
    hidden =
      Fixture.conditional(%{visible: false, data: %{}, value: "retained"}) |> Tree.flatten()

    visible =
      Fixture.conditional(%{visible: true, data: %{label: "shown"}, value: "retained"})
      |> Tree.flatten()

    assert hidden["nodes"]["root"]["children"] == ["always"]
    assert visible["nodes"]["root"]["children"] == ["optional", "always"]
    assert Tree.patch(hidden, visible, 1, 1)["remove"] == []

    assert Enum.map(Tree.patch(hidden, visible, 1, 1)["upsert"], & &1["id"]) == [
             "optional",
             "root"
           ]

    assert Tree.patch(visible, hidden, 1, 2)["remove"] == ["optional"]
    assert hidden["nodes"]["always"] == visible["nodes"]["always"]
  end

  test "expressions preserve nested braces, sigils, scalars, and generator patterns" do
    assert Fixture.expressions(%{value: "native"}).props["text"] == "native {OK} {sigil} false"

    assert Fixture.generator_pattern(%{pairs: [{"a", 1}, {"b", true}]}).children == [
             UI.text("1", id: "a"),
             UI.text("true", id: "b")
           ]
  end

  test "brace expressions accept ordinary no-parentheses Elixir calls" do
    assert Fixture.inline_calls(%{visible: true, value: "a cat"}).props["text"] == "shown b cbt"
    assert Fixture.inline_calls(%{visible: false, value: "a"}).props["text"] == "hidden b"
  end

  test "missing assigns and nonscalar text fail instead of inventing a fallback" do
    assert_raise KeyError, fn -> Fixture.counter(%{}) end
    assert_raise ArgumentError, fn -> Fixture.expressions(%{value: %{not: "text"}}) end
    assert_raise ArgumentError, fn -> Fixture.expressions(%{value: <<255>>}) end
    assert_raise ArgumentError, fn -> Template.text!(self()) end
  end

  test "repeated nodes require a real stable ID even when a runtime expression supplies it" do
    group = %{
      id: "group",
      label: "parent",
      items: [%{id: nil, name: "item", visible: true, incarnation: 0}]
    }

    assert_raise ArgumentError, fn -> Fixture.groups(%{groups: [group]}) end
    assert_raise ArgumentError, fn -> Fixture.generator_pattern(%{pairs: [{"", "invalid"}]}) end

    assert_raise ArgumentError, fn ->
      Fixture.generator_pattern(%{pairs: [{"same", "one"}, {"same", "two"}]}) |> Tree.flatten()
    end
  end

  test "the native root is exactly one unconditional element" do
    for source <- [
          "<text :if={true}>conditional</text>",
          "<row id=\"root\" :for={item <- [1]} />",
          "<text /><text />",
          "leading<text />",
          "<text />trailing"
        ] do
      assert_raise CompileError, fn -> Template.compile(source, __ENV__) end
    end
  end

  test "unsupported HTML, attributes, and directives fail with caller provenance" do
    env = %{__ENV__ | file: "native_template_fixture.ex", line: 73}

    for source <- [
          "<div />",
          "<column class=\"web\" />",
          "<button onclick=\"web()\" />",
          "<input event=\"edit\" />",
          "<row :let={item} />"
        ] do
      error = assert_raise CompileError, fn -> Template.compile(source, env) end
      assert error.file == "native_template_fixture.ex"
      assert error.line == 73
    end

    error =
      assert_raise CompileError, fn -> Template.compile("<column>\n  <div />\n</column>", env) end

    assert error.line == 74
  end

  test "malformed markup, duplicate attrs, and invalid loops are rejected by the compiler" do
    for source <- [
          "",
          "<text>unclosed",
          "<row></column>",
          "<text><row /></text>",
          "<input></input>",
          "<text id=plain />",
          "<text>{1 +}</text>",
          "<column>raw text</column>",
          "<column><text :for={item <- @items}>{item}</text></column>",
          "<column><text id=\"x\" :for={@items}>x</text></column>",
          "<column><text id=\"x\" :for=\"literal\">x</text></column>",
          "<column><text :if=\"literal\">x</text></column>",
          "<text id=\"x\" id=\"y\" />",
          "<text id=\"x\"text=\"bad\" />",
          "<text>{}</text>",
          "<text>" <> <<255>> <> "</text>"
        ] do
      assert_raise CompileError, fn -> Template.compile(source, __ENV__) end
    end
  end
end
