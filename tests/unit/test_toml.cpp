#include <gtest/gtest.h>

import std;
import mcpp.libs.toml;

namespace t = mcpp::libs::toml;

TEST(Toml, EmptyDocumentParses) {
    auto d = t::parse("");
    ASSERT_TRUE(d.has_value());
    EXPECT_TRUE(d->root().empty());
}

TEST(Toml, SimpleKeyValue) {
    auto d = t::parse("key = \"value\"\nnum = 42\nflag = true");
    ASSERT_TRUE(d.has_value()) << d.error().message;
    EXPECT_EQ(d->get_string("key").value_or(""), "value");
    EXPECT_EQ(d->get_int("num").value_or(-1), 42);
    EXPECT_EQ(d->get_bool("flag").value_or(false), true);
}

TEST(Toml, NestedTables) {
    auto d = t::parse(R"(
[a.b]
x = "deep"
[a]
y = "shallow"
)");
    ASSERT_TRUE(d.has_value()) << d.error().message;
    EXPECT_EQ(d->get_string("a.b.x").value_or(""), "deep");
    EXPECT_EQ(d->get_string("a.y").value_or(""), "shallow");
}

TEST(Toml, ArrayOfStrings) {
    auto d = t::parse(R"(items = ["a", "b", "c"])");
    ASSERT_TRUE(d.has_value());
    auto arr = d->get_string_array("items");
    ASSERT_TRUE(arr.has_value());
    EXPECT_EQ(arr->size(), 3u);
    EXPECT_EQ((*arr)[0], "a");
    EXPECT_EQ((*arr)[2], "c");
}

TEST(Toml, ArrayAllowsTrailingComma) {
    auto d = t::parse(R"(
items = [
  "a",
  "b",
]
)");
    ASSERT_TRUE(d.has_value()) << d.error().message;
    auto arr = d->get_string_array("items");
    ASSERT_TRUE(arr.has_value());
    EXPECT_EQ(*arr, std::vector<std::string>({"a", "b"}));
}

TEST(Toml, EscapedString) {
    auto d = t::parse(R"(s = "a\tb\nc")");
    ASSERT_TRUE(d.has_value());
    EXPECT_EQ(d->get_string("s").value_or(""), std::string("a\tb\nc"));
}

TEST(Toml, RejectUnterminatedString) {
    auto d = t::parse(R"(x = "no end)");
    EXPECT_FALSE(d.has_value());
}

TEST(Toml, CommentsIgnored) {
    auto d = t::parse(R"(
# top comment
x = 1  # trailing isn't supported but full-line is
y = 2
)");
    ASSERT_TRUE(d.has_value()) << d.error().message;
    EXPECT_EQ(d->get_int("x").value_or(-1), 1);
    EXPECT_EQ(d->get_int("y").value_or(-1), 2);
}

TEST(Toml, EscapeStringHelper) {
    EXPECT_EQ(t::escape_string("hello"), "\"hello\"");
    EXPECT_EQ(t::escape_string("a\"b"),  "\"a\\\"b\"");
    EXPECT_EQ(t::escape_string("a\\b"),  "\"a\\\\b\"");
}

TEST(Toml, MultilineBasicString) {
    auto d = t::parse("body = \"\"\"\nline1\nline2 \"quoted\"\n\"\"\"\nafter = 1");
    ASSERT_TRUE(d.has_value()) << d.error().message;
    // First newline after the opening delimiter is trimmed (TOML 1.0).
    EXPECT_EQ(d->get_string("body").value_or(""), "line1\nline2 \"quoted\"\n");
    EXPECT_EQ(d->get_int("after").value_or(-1), 1);
}

TEST(Toml, MultilineLiteralString) {
    auto d = t::parse("raw = '''\nno \\escapes here\n'''");
    ASSERT_TRUE(d.has_value()) << d.error().message;
    EXPECT_EQ(d->get_string("raw").value_or(""), "no \\escapes here\n");
}

TEST(Toml, MultilineLineEndingBackslash) {
    auto d = t::parse("s = \"\"\"a\\\n   b\"\"\"");
    ASSERT_TRUE(d.has_value()) << d.error().message;
    EXPECT_EQ(d->get_string("s").value_or(""), "ab");
}

TEST(Toml, MultilineUnterminatedIsError) {
    auto d = t::parse("s = \"\"\"never closed");
    EXPECT_FALSE(d.has_value());
}

TEST(Toml, EmptyStringStillParses) {
    auto d = t::parse("e = \"\"\nx = 2");
    ASSERT_TRUE(d.has_value()) << d.error().message;
    EXPECT_EQ(d->get_string("e").value_or("?"), "");
    EXPECT_EQ(d->get_int("x").value_or(-1), 2);
}

// #227: `[[dotted.path]]` array-of-tables — each occurrence appends a fresh
// table to an array at that dotted path; keys after it fill THAT table until
// the next `[...]`/`[[...]]` header. Declaration order must be preserved
// (it's the "later entries win" override order for [build].flags).
TEST(Toml, ParsesArrayOfTables) {
    auto d = t::parse(R"(
[[build.flags]]
glob = "a/**"
cxxflags = ["-DX=1"]
[[build.flags]]
glob = "b/**"
)");
    ASSERT_TRUE(d.has_value()) << d.error().message;
    auto* v = d->get("build.flags");
    ASSERT_NE(v, nullptr);
    ASSERT_TRUE(v->is_array());
    auto& arr = v->as_array();
    ASSERT_EQ(arr.size(), 2u);
    ASSERT_TRUE(arr[0].is_table());
    EXPECT_EQ(arr[0].as_table().at("glob").as_string(), "a/**");
    auto cx = arr[0].as_table().at("cxxflags");
    ASSERT_TRUE(cx.is_array());
    ASSERT_EQ(cx.as_array().size(), 1u);
    EXPECT_EQ(cx.as_array()[0].as_string(), "-DX=1");
    ASSERT_TRUE(arr[1].is_table());
    EXPECT_EQ(arr[1].as_table().at("glob").as_string(), "b/**");
    EXPECT_EQ(arr[1].as_table().count("cxxflags"), 0u);
}

// Regular `[table]` and inline-array-of-tables parsing must be unaffected by
// AOT support — array-of-tables is an ADDITIONAL grammar form, not a
// replacement.
TEST(Toml, RegularTablesStillWorkAlongsideArrayOfTables) {
    auto d = t::parse(R"(
[package]
name = "x"
[[build.flags]]
glob = "a/**"
[dependencies]
foo = "1.0"
)");
    ASSERT_TRUE(d.has_value()) << d.error().message;
    EXPECT_EQ(d->get_string("package.name").value_or(""), "x");
    EXPECT_EQ(d->get_string("dependencies.foo").value_or(""), "1.0");
    auto* v = d->get("build.flags");
    ASSERT_NE(v, nullptr);
    ASSERT_TRUE(v->is_array());
    EXPECT_EQ(v->as_array().size(), 1u);
}
