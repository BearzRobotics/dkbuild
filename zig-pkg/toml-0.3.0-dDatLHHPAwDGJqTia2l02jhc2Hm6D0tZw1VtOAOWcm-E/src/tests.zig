//! Tests derived from the examples in the TOML 1.0.0 specification
//! (https://toml.io/en/v1.0.0) and from its stated invalid cases.

const std = @import("std");
const toml = @import("root.zig");
const testing = std.testing;

const TrickleReader = @import("io_tests.zig").TrickleReader;
const expectSameTree = @import("test_util.zig").expectSameTree;

const V10: toml.Options = .{ .version = .v1_0 };
const V11: toml.Options = .{ .version = .v1_1 };

/// Parses with `opts`, and again one byte at a time through a Reader with no
/// buffer of its own; the result must be identical.
fn parseWith(opts: toml.Options, src: []const u8) !toml.Document {
    var diag: toml.Diagnostic = .{};
    var doc = toml.Document.parse(testing.allocator, src, opts, &diag) catch |e| {
        std.debug.print("unexpected failure on {s}: {f}\n", .{ src, diag });
        return e;
    };
    errdefer doc.deinit();
    var tr = TrickleReader.init(src, 1, null);
    var diag2: toml.Diagnostic = .{};
    var doc2 = toml.Document.parseReader(testing.allocator, &tr.interface, opts, &diag2) catch |e| {
        std.debug.print("one-byte reader failed on {s}: {f}\n", .{ src, diag2 });
        return e;
    };
    defer doc2.deinit();
    try expectSameTree(doc.root, doc2.root);
    const a = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(a);
    const b = try doc2.toOwnedString(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
    return doc;
}

/// A document valid in TOML 1.0. It must also be valid in 1.1 and mean the
/// same thing; returns the 1.0 result.
fn parseOk(src: []const u8) !toml.Document {
    var doc = try parseWith(V10, src);
    errdefer doc.deinit();
    var doc11 = try parseWith(V11, src);
    defer doc11.deinit();
    try expectSameTree(doc.root, doc11.root);
    const a = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(a);
    const b = try doc11.toOwnedString(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
    return doc;
}

/// A wrapper, so that an expected parse error is a value rather than a failure
/// of the helper that reports it.
const Rejection = struct { err: anyerror };

/// The error `src` is rejected with, or null if it parses.
fn rejects(opts: toml.Options, src: []const u8) !?Rejection {
    var diag: toml.Diagnostic = .{};
    if (toml.Document.parse(testing.allocator, src, opts, &diag)) |*doc| {
        var d = doc.*;
        d.deinit();
        return null;
    } else |e| {
        // The error and its diagnostic must not depend on how bytes arrive.
        var tr = TrickleReader.init(src, 1, null);
        var diag2: toml.Diagnostic = .{};
        try testing.expectError(e, toml.Document.parseReader(testing.allocator, &tr.interface, opts, &diag2));
        try testing.expectEqual(diag.line, diag2.line);
        try testing.expectEqual(diag.column, diag2.column);
        try testing.expectEqualStrings(diag.message, diag2.message);
        return .{ .err = e };
    }
}

/// A syntax error in every TOML version. Any other error is a test failure.
fn expectInvalid(src: []const u8) !void {
    for ([_]toml.Options{ V10, V11 }) |opts| {
        const r = try rejects(opts, src) orelse {
            std.debug.print("accepted invalid input ({t}): {s}\n", .{ opts.version, src });
            return error.AcceptedInvalid;
        };
        try testing.expectEqual(@as(anyerror, error.Syntax), r.err);
    }
}

/// A syntax error in TOML 1.0 but valid in 1.1.
fn expectOnly11(src: []const u8) !void {
    const r = try rejects(V10, src) orelse {
        std.debug.print("1.0 accepted a 1.1-only input: {s}\n", .{src});
        return error.AcceptedInvalid;
    };
    try testing.expectEqual(@as(anyerror, error.Syntax), r.err);
    var doc = try parseWith(V11, src);
    doc.deinit();
}

test "key/value basics and comments" {
    var doc = try parseOk(
        \\# comment
        \\key = "value" # trailing
        \\bare_key-1 = 1
        \\"quoted key" = true
        \\'lit key' = false
        \\
    );
    defer doc.deinit();
    try testing.expectEqualStrings("value", doc.root.getString("key").?);
    try testing.expectEqual(@as(i64, 1), doc.root.getInt("bare_key-1").?);
    try testing.expectEqual(true, doc.root.getBool("quoted key").?);
    try testing.expectEqual(false, doc.root.getBool("lit key").?);
}

test "invalid key/value forms" {
    try expectInvalid("key = # INVALID");
    try expectInvalid("first = \"Tom\" last = \"Preston-Werner\"");
    try expectInvalid("= \"no key name\"");
    try expectInvalid("a = 1\na = 2");
    try expectInvalid("a = 1\n\"a\" = 2");
    try expectInvalid("name = \"Tom\"\nname = \"Pradyun\"");
}

test "dotted keys" {
    var doc = try parseOk(
        \\name = "Orange"
        \\physical.color = "orange"
        \\physical.shape = "round"
        \\site."google.com" = true
        \\fruit . flavor = "banana"
    );
    defer doc.deinit();
    try testing.expectEqualStrings("orange", doc.root.lookup("physical.color").?.string);
    try testing.expectEqual(true, doc.root.getTable("site").?.getBool("google.com").?);
    try testing.expectEqualStrings("banana", doc.root.lookup("fruit.flavor").?.string);
}

test "dotted key conflicts" {
    try expectInvalid("fruit.apple = 1\nfruit.apple.smooth = true");
    try expectInvalid("[fruit]\napple.color = \"red\"\n[fruit.apple]");
    try expectInvalid("[fruit]\napple.color = \"red\"\napple.taste.sweet = true\n[fruit.apple.taste]");
    try expectInvalid("[a.b.c]\nz = 9\n[a]\nb.c.t = 1");
}

test "dotted keys may be extended by deeper headers" {
    var doc = try parseOk(
        \\[fruit]
        \\apple.color = "red"
        \\apple.taste.sweet = true
        \\[fruit.apple.texture]
        \\smooth = true
    );
    defer doc.deinit();
    try testing.expectEqual(true, doc.root.lookup("fruit.apple.texture.smooth").?.boolean);
    try testing.expectEqual(true, doc.root.lookup("fruit.apple.taste.sweet").?.boolean);
}

test "strings: basic escapes" {
    var doc = try parseOk(
        \\a = "I'm a string. \"You can quote me\". Name\tJos\u00E9\nLocation\tSF."
        \\b = "\U0001F600 \\ \b\f\r"
    );
    defer doc.deinit();
    try testing.expectEqualStrings("I'm a string. \"You can quote me\". Name\tJos\u{E9}\nLocation\tSF.", doc.root.getString("a").?);
    try testing.expectEqualStrings("\u{1F600} \\ \x08\x0C\r", doc.root.getString("b").?);
}

test "strings: invalid" {
    try expectInvalid("a = \"bad \\x escape\"");
    try expectInvalid("a = \"unterminated");
    try expectInvalid("a = \"new\nline\"");
    try expectInvalid("a = \"\\uD800\"");
    try expectInvalid("a = \"\\U00110000\"");
    try expectInvalid("a = \"\\u12\"");
    try expectInvalid("a = \"\\u+123\"");
    try expectInvalid("a = \"nul \x00 char\"");
    try expectInvalid("a = \"del \x7f char\"");
    try expectInvalid("a = 'new\nline'");
}

test "strings: multi-line" {
    var doc = try parseOk(
        "a = \"\"\"\nRoses are red\nViolets are blue\"\"\"\n" ++
            "b = \"\"\"\nThe quick brown \\\n\n   fox jumps over \\\n the lazy dog.\"\"\"\n" ++
            "c = \"\"\"Here are two quotation marks: \"\". Simple enough.\"\"\"\n" ++
            "d = \"\"\"Here are three quotation marks: \"\"\\\".\"\"\"\n" ++
            "e = \"\"\"\"This,\" she said, \"is just a pointless statement.\"\"\"\"\n" ++
            "f = '''\nfirst\n  second'''\n" ++
            "g = ''''That,' she said, 'is still pointless.''''\n" ++
            "h = '''I [dw]on't need \\d{2} apples'''\n",
    );
    defer doc.deinit();
    try testing.expectEqualStrings("Roses are red\nViolets are blue", doc.root.getString("a").?);
    try testing.expectEqualStrings("The quick brown fox jumps over the lazy dog.", doc.root.getString("b").?);
    try testing.expectEqualStrings("Here are two quotation marks: \"\". Simple enough.", doc.root.getString("c").?);
    try testing.expectEqualStrings("Here are three quotation marks: \"\"\".", doc.root.getString("d").?);
    try testing.expectEqualStrings("\"This,\" she said, \"is just a pointless statement.\"", doc.root.getString("e").?);
    try testing.expectEqualStrings("first\n  second", doc.root.getString("f").?);
    try testing.expectEqualStrings("'That,' she said, 'is still pointless.'", doc.root.getString("g").?);
    try testing.expectEqualStrings("I [dw]on't need \\d{2} apples", doc.root.getString("h").?);
}

test "strings: multi-line invalid" {
    try expectInvalid("a = \"\"\"unterminated");
    try expectInvalid("a = \"\"\"six \"\"\"\"\"\"");
    try expectInvalid("a = '''unterminated");
}

test "strings: literal keeps backslashes" {
    var doc = try parseOk("winpath = 'C:\\Users\\nodejs\\templates'\nregex = '<\\i\\c*\\s*>'\n");
    defer doc.deinit();
    try testing.expectEqualStrings("C:\\Users\\nodejs\\templates", doc.root.getString("winpath").?);
    try testing.expectEqualStrings("<\\i\\c*\\s*>", doc.root.getString("regex").?);
}

test "integers" {
    var doc = try parseOk(
        \\int1 = +99
        \\int2 = 42
        \\int3 = 0
        \\int4 = -17
        \\int5 = 1_000
        \\int6 = 5_349_221
        \\int7 = 53_49_221
        \\int8 = 1_2_3_4_5
        \\hex1 = 0xDEADBEEF
        \\hex2 = 0xdeadbeef
        \\hex3 = 0xdead_beef
        \\oct1 = 0o01234567
        \\oct2 = 0o755
        \\bin1 = 0b11010110
        \\min = -9223372036854775808
        \\max = 9223372036854775807
        \\zero = -0
    );
    defer doc.deinit();
    const want = [_]struct { []const u8, i64 }{
        .{ "int1", 99 },                  .{ "int2", 42 },
        .{ "int3", 0 },                   .{ "int4", -17 },
        .{ "int5", 1000 },                .{ "int6", 5349221 },
        .{ "int7", 5349221 },             .{ "int8", 12345 },
        .{ "hex1", 0xDEADBEEF },          .{ "hex2", 0xDEADBEEF },
        .{ "hex3", 0xDEADBEEF },          .{ "oct1", 0o01234567 },
        .{ "oct2", 493 },                 .{ "bin1", 214 },
        .{ "zero", 0 },                   .{ "min", std.math.minInt(i64) },
        .{ "max", std.math.maxInt(i64) },
    };
    try testing.expectEqual(want.len, doc.root.count());
    for (want) |w| try testing.expectEqual(w[1], doc.root.getInt(w[0]).?);
}

test "integers: invalid" {
    try expectInvalid("a = 01");
    try expectInvalid("a = +01");
    try expectInvalid("a = 1__0");
    try expectInvalid("a = _1");
    try expectInvalid("a = 1_");
    try expectInvalid("a = 0x_1");
    try expectInvalid("a = 0x");
    try expectInvalid("a = +0x1");
    try expectInvalid("a = 0o8");
    try expectInvalid("a = 0b2");
    try expectInvalid("a = 9223372036854775808");
    try expectInvalid("a = -9223372036854775809");
    try expectInvalid("a = 0xFFFFFFFFFFFFFFFF");
    try expectInvalid("a = 12abc");
    try expectInvalid("a = 1 2");
}

test "floats" {
    var doc = try parseOk(
        \\flt1 = +1.0
        \\flt2 = 3.1415
        \\flt3 = -0.01
        \\flt4 = 5e+22
        \\flt5 = 1e06
        \\flt6 = -2E-2
        \\flt7 = 6.626e-34
        \\flt8 = 224_617.445_991_228
        \\sf1 = inf
        \\sf2 = +inf
        \\sf3 = -inf
        \\sf4 = nan
        \\sf5 = +nan
    );
    defer doc.deinit();
    const r = doc.root;
    const inf = std.math.inf(f64);
    const want = [_]struct { []const u8, f64 }{
        .{ "flt1", 1.0 },       .{ "flt2", 3.1415 },           .{ "flt3", -0.01 },
        .{ "flt4", 5e22 },      .{ "flt5", 1e6 },              .{ "flt6", -0.02 },
        .{ "flt7", 6.626e-34 }, .{ "flt8", 224617.445991228 }, .{ "sf1", inf },
        .{ "sf2", inf },        .{ "sf3", -inf },
    };
    for (want) |w| try testing.expectEqual(w[1], r.get(w[0]).?.float);
    try testing.expect(std.math.isNan(r.get("sf4").?.float));
    try testing.expect(std.math.isNan(r.get("sf5").?.float));
    // An integer is accepted by getFloat, but a float is not an integer.
    try testing.expect(r.getInt("flt1") == null);
}

test "floats: invalid" {
    try expectInvalid("a = .7");
    try expectInvalid("a = 7.");
    try expectInvalid("a = 3.e+20");
    try expectInvalid("a = 1e");
    try expectInvalid("a = 1e+");
    try expectInvalid("a = 01.5");
    try expectInvalid("a = 1._5");
    try expectInvalid("a = 1_.5");
    try expectInvalid("a = 1e_1");
    try expectInvalid("a = 1.5.2");
    try expectInvalid("a = Inf");
    try expectInvalid("a = NaN");
    try expectInvalid("a = 0x1p3");
}

test "floats: too large for 64 bits is an error, not infinity" {
    for ([_][]const u8{ "a = 1e400", "a = -1e400", "a = +1.8e308", "a = 1_0.0e3_08" }) |src| {
        try expectInvalid(src);
        try expectDiagnostic(.{ .src = src, .line = 1, .column = 5, .message = "float out of range" });
    }
    // The largest finite value, and values that round toward zero, still load.
    var doc = try parseOk("max = 1.7976931348623157e308\nmin = -1.7976931348623157e308\ntiny = 1e-400\ni = -inf\n");
    defer doc.deinit();
    try testing.expectEqual(std.math.floatMax(f64), doc.root.getFloat("max").?);
    try testing.expectEqual(-std.math.floatMax(f64), doc.root.getFloat("min").?);
    try testing.expectEqual(@as(f64, 0), doc.root.getFloat("tiny").?);
    try testing.expect(std.math.isNegativeInf(doc.root.getFloat("i").?));
}

test "booleans" {
    var doc = try parseOk("a = true\nb = false\n");
    defer doc.deinit();
    try testing.expectEqual(true, doc.root.getBool("a").?);
    try testing.expectEqual(false, doc.root.getBool("b").?);
    try expectInvalid("a = True");
    try expectInvalid("a = TRUE");
}

test "datetimes" {
    var doc = try parseOk(
        \\odt1 = 1979-05-27T07:32:00Z
        \\odt2 = 1979-05-27T00:32:00-07:00
        \\odt3 = 1979-05-27T00:32:00.999999-07:00
        \\odt4 = 1979-05-27 07:32:00Z
        \\ldt1 = 1979-05-27T07:32:00
        \\ldt2 = 1979-05-27T00:32:00.999999
        \\ld1 = 1979-05-27
        \\lt1 = 07:32:00
        \\lt2 = 00:32:00.999999
        \\leap = 2024-02-29
    );
    defer doc.deinit();
    // Every field of every value, through the canonical spelling.
    const want = [_]struct { []const u8, []const u8 }{
        .{ "odt1", "1979-05-27T07:32:00Z" },
        .{ "odt2", "1979-05-27T00:32:00-07:00" },
        .{ "odt3", "1979-05-27T00:32:00.999999-07:00" },
        .{ "odt4", "1979-05-27T07:32:00Z" },
        .{ "ldt1", "1979-05-27T07:32:00" },
        .{ "ldt2", "1979-05-27T00:32:00.999999" },
        .{ "ld1", "1979-05-27" },
        .{ "lt1", "07:32:00" },
        .{ "lt2", "00:32:00.999999" },
        .{ "leap", "2024-02-29" },
    };
    for (want) |w| {
        var buf: [64]u8 = undefined;
        const got = try std.fmt.bufPrint(&buf, "{f}", .{doc.root.get(w[0]).?.datetime});
        try testing.expectEqualStrings(w[1], got);
    }
    // And the fields themselves, so the check does not rest on `format` alone.
    const odt3 = doc.root.get("odt3").?.datetime;
    try testing.expectEqual(toml.Date{ .year = 1979, .month = 5, .day = 27 }, odt3.date.?);
    try testing.expectEqual(toml.Time{ .hour = 0, .minute = 32, .second = 0, .nanosecond = 999999000 }, odt3.time.?);
    try testing.expectEqual(@as(i16, -420), odt3.offset_minutes.?);
    const lt1 = doc.root.get("lt1").?.datetime;
    try testing.expect(lt1.date == null and lt1.offset_minutes == null);
    try testing.expect(doc.root.get("ld1").?.datetime.time == null);
    try testing.expect(doc.root.get("ldt1").?.datetime.offset_minutes == null);
}

test "datetimes: invalid" {
    try expectInvalid("a = 2023-02-29");
    try expectInvalid("a = 1979-13-01");
    try expectInvalid("a = 1979-00-10");
    try expectInvalid("a = 1979-05-32");
    try expectInvalid("a = 1979-05-27T25:00:00");
    try expectInvalid("a = 1979-05-27T07:60:00");
    try expectInvalid("a = 07:32:00Z");
    try expectOnly11("a = 07:32");
    try expectInvalid("a = 1979-05-27T07:32:00+0700");
    try expectInvalid("a = 1979-5-27");
    try expectInvalid("a = 07:32:00.");
}

test "arrays" {
    var doc = try parseOk(
        \\integers = [ 1, 2, 3 ]
        \\colors = [ "red", "yellow", "green" ]
        \\nested = [ [ 1, 2 ], ["a", "b", "c"] ]
        \\mixed = [ 1, "two", 3.0, [ true ], { x = 1 } ]
        \\multi = [
        \\  1, # one
        \\  2,
        \\  # nothing
        \\  3,
        \\]
        \\empty = []
    );
    defer doc.deinit();
    const r = doc.root;
    try testing.expectEqual(@as(usize, 3), r.getArray("integers").?.items.items.len);
    try testing.expectEqual(@as(usize, 2), r.getArray("nested").?.items.items.len);
    try testing.expectEqual(@as(usize, 5), r.getArray("mixed").?.items.items.len);
    try testing.expectEqual(@as(usize, 3), r.getArray("multi").?.items.items.len);
    try testing.expectEqual(@as(usize, 0), r.getArray("empty").?.items.items.len);
}

test "arrays: invalid" {
    try expectInvalid("a = [1, 2");
    try expectInvalid("a = [1 2]");
    try expectInvalid("a = [,]");
    try expectInvalid("a = [1,,2]");
}

test "tables" {
    var doc = try parseOk(
        \\[table-1]
        \\key1 = "some string"
        \\[table-2]
        \\key1 = "another string"
        \\[dog."tater.man"]
        \\type.name = "pug"
        \\[ j . "ʞ" . 'l' ]
        \\x = 1
    );
    defer doc.deinit();
    try testing.expectEqualStrings("pug", doc.root.getTable("dog").?.getTable("tater.man").?.lookup("type.name").?.string);
    try testing.expectEqual(@as(i64, 1), doc.root.getTable("j").?.getTable("ʞ").?.getTable("l").?.getInt("x").?);
}

test "tables: super table defined after" {
    var doc = try parseOk(
        \\[x.y.z.w]
        \\a = 1
        \\[x]
        \\b = 2
    );
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 2), doc.root.getTable("x").?.getInt("b").?);
    try testing.expectEqual(@as(i64, 1), doc.root.lookup("x.y.z.w.a").?.integer);
}

test "tables: invalid" {
    try expectInvalid("[a]\n[a]");
    try expectInvalid("[a]\nb = 1\n[a.b]");
    try expectInvalid("[a]\nb = 1\n[a]\nc = 2");
    try expectInvalid("[]");
    try expectInvalid("[a.]");
    try expectInvalid("[.a]");
    try expectInvalid("[a..b]");
    try expectInvalid("[a");
    try expectInvalid("[a] b = 1");
    try expectInvalid("a = 1\n[a]");
    try expectInvalid("[fruit]\napple = \"red\"\n[fruit.apple]");
    try expectInvalid("[fruit]\napple = \"red\"\n[fruit.apple.texture]");
}

test "inline tables" {
    var doc = try parseOk(
        \\name = { first = "Tom", last = "Preston-Werner" }
        \\point = { x = 1, y = 2 }
        \\animal = { type.name = "pug" }
        \\empty = {}
    );
    defer doc.deinit();
    try testing.expectEqualStrings("Tom", doc.root.lookup("name.first").?.string);
    try testing.expectEqualStrings("pug", doc.root.lookup("animal.type.name").?.string);
    try testing.expectEqual(@as(usize, 0), doc.root.getTable("empty").?.count());
}

test "inline tables: invalid" {
    try expectOnly11("a = { x = 1,\n y = 2 }");
    try expectOnly11("a = { x = 1, }");
    try expectInvalid("a = { x = 1 y = 2 }");
    try expectInvalid("a = { x = 1, x = 2 }");
    try expectInvalid("a = { x = 1 }\n[a]");
    try expectInvalid("a = { x = 1 }\n[a.b]");
    try expectInvalid("a = { b = {} }\n[a.b]");
    try expectInvalid("a = { x = 1 }\na.y = 2");
    try expectInvalid("a = { x = 1");
}

test "array of tables" {
    var doc = try parseOk(
        \\[[products]]
        \\name = "Hammer"
        \\sku = 738594937
        \\[[products]]  # empty table within the array
        \\[[products]]
        \\name = "Nail"
        \\[[fruits]]
        \\name = "apple"
        \\[fruits.physical]
        \\color = "red"
        \\[[fruits.varieties]]
        \\name = "red delicious"
        \\[[fruits.varieties]]
        \\name = "granny smith"
        \\[[fruits]]
        \\name = "banana"
        \\[[fruits.varieties]]
        \\name = "plantain"
    );
    defer doc.deinit();
    const products = doc.root.getArray("products").?;
    try testing.expectEqual(@as(usize, 3), products.items.items.len);
    try testing.expectEqual(@as(usize, 0), products.items.items[1].table.count());
    const fruits = doc.root.getArray("fruits").?;
    try testing.expectEqual(@as(usize, 2), fruits.items.items.len);
    const apple = fruits.items.items[0].table;
    try testing.expectEqualStrings("red", apple.lookup("physical.color").?.string);
    try testing.expectEqual(@as(usize, 2), apple.getArray("varieties").?.items.items.len);
    try testing.expectEqual(@as(usize, 1), fruits.items.items[1].table.getArray("varieties").?.items.items.len);
}

test "array of tables: invalid" {
    try expectInvalid("a = [1]\n[[a]]");
    try expectInvalid("a = [{x = 1}]\n[[a]]");
    try expectInvalid("[[a]]\n[a]");
    try expectInvalid("[a]\n[[a]]");
    try expectInvalid("a = 1\n[[a]]");
    try expectInvalid("[[a]\n");
    try expectInvalid("[[a]]]\n");
    try expectInvalid("a = [{x = 1}]\n[a.b]");
}

test "line endings, BOM, whitespace" {
    var doc = try parseOk("\xEF\xBB\xBFa = 1\r\nb = \"\"\"x\r\ny\"\"\"\r\n[t]\r\nc = 2");
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.root.getInt("a").?);
    try testing.expectEqualStrings("x\r\ny", doc.root.getString("b").?);
    try expectInvalid("a = 1\rb = 2");
    try expectInvalid("a = 1 # bare \r cr");
    try expectInvalid("a = 1 # nul \x00");
}

fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    @setEvalBranchQuota(100_000);
    comptime var out: [s.len * n]u8 = undefined;
    inline for (0..n) |i| out[i * s.len ..][0..s.len].* = s.*;
    const final = out;
    return &final;
}

test "invalid UTF-8 and limits" {
    var diag: toml.Diagnostic = .{};
    try testing.expectError(error.InvalidUtf8, toml.Document.parse(testing.allocator, "a = \"\xff\"", .{}, &diag));
    try testing.expectEqual(@as(usize, 1), diag.line);
    try testing.expectError(error.LimitExceeded, toml.Document.parse(testing.allocator, "a = 1", .{ .max_bytes = 2 }, null));
    // Deep nesting must be rejected rather than overflow the stack.
    const deep = "a = " ++ rep("[", 100) ++ rep("]", 100);
    try testing.expectError(error.LimitExceeded, toml.Document.parse(testing.allocator, deep, .{}, null));
    const ok = "a = " ++ rep("[", 60) ++ rep("]", 60);
    var d = try toml.Document.parse(testing.allocator, ok, .{}, null);
    d.deinit();
    const deep_inline = "a = " ++ rep("{ b = ", 100) ++ "1" ++ rep(" }", 100);
    try testing.expectError(error.LimitExceeded, toml.Document.parse(testing.allocator, deep_inline, .{}, null));
}

const Expected = struct {
    src: []const u8,
    err: anyerror = error.Syntax,
    line: usize,
    column: usize,
    message: []const u8,
    options: toml.Options = .{},
};

fn expectDiagnostic(x: Expected) !void {
    var diag: toml.Diagnostic = .{};
    if (toml.Document.parse(testing.allocator, x.src, x.options, &diag)) |*doc| {
        var d = doc.*;
        d.deinit();
        return error.AcceptedInvalid;
    } else |e| try testing.expectEqual(x.err, @as(anyerror, e));
    errdefer std.debug.print("input: {s}\ngot: {f}\n", .{ x.src, diag });
    try testing.expectEqual(x.line, diag.line);
    try testing.expectEqual(x.column, diag.column);
    try testing.expectEqualStrings(x.message, diag.message);
}

test "bytes that are not UTF-8 are InvalidUtf8 wherever they are met" {
    const Case = struct { []const u8, usize, usize };
    for ([_]Case{
        // Places where the grammar stops before taking the byte.
        .{ "\xff = 1", 1, 1 },
        .{ "a = 1\n\xff", 2, 1 },
        .{ "a = 1 \xff", 1, 7 },
        .{ "[\xff]", 1, 2 },
        .{ "[a\xff]", 1, 3 },
        .{ "a \xc0\x80", 1, 3 },
        .{ "a = [1 \xed\xa0\x80]", 1, 8 },
        .{ "a = {b = 1 \xe2\x82", 1, 12 },
        .{ "a = 1 \x80", 1, 7 },
    }) |c| {
        try expectDiagnostic(.{ .src = c[0], .err = error.InvalidUtf8, .line = c[1], .column = c[2], .message = "invalid UTF-8" });
        const r = (try rejects(V11, c[0])).?;
        try testing.expectEqual(@as(anyerror, error.InvalidUtf8), r.err);
    }
    // Well-formed text in the wrong place is still a syntax error.
    try expectDiagnostic(.{ .src = "\u{e9} = 1", .line = 1, .column = 1, .message = "expected key" });
    try expectDiagnostic(.{ .src = "a = 1 \u{1F600}", .line = 1, .column = 7, .message = "expected end of line" });
}

test "a reused diagnostic never shows an earlier result" {
    const gpa = testing.allocator;
    var diag: toml.Diagnostic = .{};
    try testing.expectError(error.Syntax, toml.Document.parse(gpa, "a = @", .{}, &diag));
    var ok = try toml.Document.parse(gpa, "a = 1", .{}, &diag);
    ok.deinit();
    try testing.expectEqualDeep(toml.Diagnostic{}, diag);

    var tr = TrickleReader.init("a = 1\nbb = 2\n", 1, 8);
    try testing.expectError(error.ReadFailed, toml.Document.parseReader(gpa, &tr.interface, .{}, &diag));
    try testing.expectEqualDeep(toml.Diagnostic{ .line = 2, .column = 3, .message = "read failed" }, diag);

    // Out of memory at every point, including before parsing starts.
    var index: usize = 0;
    while (true) : (index += 1) {
        diag = .{ .line = 99, .column = 99, .message = "stale" };
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = index, .resize_fail_index = 0 });
        var doc = toml.Document.parse(failing.allocator(), "a.b = [1, 2]\n", .{}, &diag) catch |e| {
            try testing.expectEqual(error.OutOfMemory, e);
            try testing.expectEqualStrings("out of memory", diag.message);
            try testing.expect(diag.line >= 1 and diag.line <= 2 and diag.column >= 1);
            continue;
        };
        doc.deinit();
        break;
    }
    try testing.expect(index > 0);
}

test "diagnostics report line, column and message" {
    for ([_]Expected{
        .{ .src = "a = 1\nb = 2\nc = @\n", .line = 3, .column = 5, .message = "invalid integer" },
        .{ .src = "a = 1\na = 2\n", .line = 2, .column = 1, .message = "duplicate key" },
        .{ .src = "[a]\n  [a]\n", .line = 2, .column = 3, .message = "table defined more than once" },
        .{ .src = "key value", .line = 1, .column = 5, .message = "expected '=' after key" },
        .{ .src = "a = \"x\\q\"", .line = 1, .column = 7, .message = "invalid escape sequence" },
        .{ .src = "a = \"abc\n", .line = 1, .column = 9, .message = "newline in single-line string" },
        .{ .src = "a = [1 2]", .line = 1, .column = 8, .message = "expected ',' or ']' in array" },
        .{ .src = "a = 1 b", .line = 1, .column = 7, .message = "expected end of line" },
        .{ .src = "\n\n  = 1", .line = 3, .column = 3, .message = "expected key" },
        .{ .src = "a = 2023-02-29", .line = 1, .column = 5, .message = "invalid date or time" },
        .{ .src = "a = 99999999999999999999", .line = 1, .column = 5, .message = "integer out of range" },
        // A byte-order mark takes up no column.
        .{ .src = "\xEF\xBB\xBFa = @", .line = 1, .column = 5, .message = "invalid integer" },
        .{ .src = "\xEF\xBB\xBFa = 1\nb", .line = 2, .column = 2, .message = "expected '=' after key" },
        // Columns count code points, not bytes.
        .{ .src = "a = \"\u{e9}\u{20ac}\" x", .line = 1, .column = 10, .message = "expected end of line" },
        .{ .src = "a = \"\xff\"", .err = error.InvalidUtf8, .line = 1, .column = 6, .message = "invalid UTF-8" },
        .{ .src = "a = 12", .err = error.LimitExceeded, .line = 1, .column = 6, .message = "input too large", .options = .{ .max_bytes = 5 } },
        .{ .src = "a = [[1]]", .err = error.LimitExceeded, .line = 1, .column = 6, .message = "nesting too deep", .options = .{ .max_depth = 1 } },
    }) |x| try expectDiagnostic(x);
}

test "empty and comment-only documents" {
    var doc = try parseOk("");
    doc.deinit();
    doc = try parseOk("# just a comment");
    doc.deinit();
    doc = try parseOk("\n\n   \n\t\n");
    doc.deinit();
}

test "full example from the spec" {
    var doc = try parseOk(
        \\# This is a TOML document.
        \\title = "TOML Example"
        \\[owner]
        \\name = "Tom Preston-Werner"
        \\dob = 1979-05-27T07:32:00-08:00
        \\[database]
        \\enabled = true
        \\ports = [ 8000, 8001, 8002 ]
        \\data = [ ["delta", "phi"], [3.14] ]
        \\temp_targets = { cpu = 79.5, case = 72.0 }
        \\[servers]
        \\[servers.alpha]
        \\ip = "10.0.0.1"
        \\role = "frontend"
        \\[servers.beta]
        \\ip = "10.0.0.2"
        \\role = "backend"
    );
    defer doc.deinit();
    try testing.expectEqualStrings("10.0.0.2", doc.root.lookup("servers.beta.ip").?.string);
    try testing.expectEqual(@as(f64, 79.5), doc.root.lookup("database.temp_targets.cpu").?.float);
}

// ---- boundaries ------------------------------------------------------------

fn expectValid(src: []const u8) !void {
    var doc = try parseOk(src);
    doc.deinit();
}

test "datetimes: calendar and range boundaries" {
    try expectValid("a = 2000-02-29"); // divisible by 400: leap
    try expectInvalid("a = 1900-02-29"); // divisible by 100 only: not leap
    try expectInvalid("a = 2100-02-29");
    for ([_]u8{ 4, 6, 9, 11 }) |month| {
        var buf: [32]u8 = undefined;
        try expectValid(try std.fmt.bufPrint(&buf, "a = 2024-{d:0>2}-30", .{month}));
        try expectInvalid(try std.fmt.bufPrint(&buf, "a = 2024-{d:0>2}-31", .{month}));
    }
    for ([_]u8{ 1, 3, 5, 7, 8, 10, 12 }) |month| {
        var buf: [32]u8 = undefined;
        try expectValid(try std.fmt.bufPrint(&buf, "a = 2024-{d:0>2}-31", .{month}));
    }
    try expectInvalid("a = 2024-01-00");
    try expectValid("a = 23:59:60"); // leap second
    try expectInvalid("a = 23:59:61");
    try expectValid("a = 1979-05-27T07:32:00+23:59");
    try expectValid("a = 1979-05-27T07:32:00-23:59");
    try expectInvalid("a = 1979-05-27T07:32:00+24:00");
    try expectInvalid("a = 1979-05-27T07:32:00+00:60");
}

test "max_depth and max_bytes are exact" {
    const gpa = testing.allocator;
    var at_depth = try toml.Document.parse(gpa, "a = " ++ rep("[", 64) ++ rep("]", 64), .{}, null);
    at_depth.deinit();
    try testing.expectError(error.LimitExceeded, toml.Document.parse(gpa, "a = " ++ rep("[", 65) ++ rep("]", 65), .{}, null));
    var at_size = try toml.Document.parse(gpa, "a = 1", .{ .max_bytes = 5 }, null);
    at_size.deinit();
    try testing.expectError(error.LimitExceeded, toml.Document.parse(gpa, "a = 1", .{ .max_bytes = 4 }, null));
}

test "CRLF is kept inside both kinds of multi-line string" {
    var doc = try parseOk("b = \"\"\"\r\nx\r\ny\"\"\"\r\nl = '''\r\nx\r\ny'''\r\n");
    defer doc.deinit();
    try testing.expectEqualStrings("x\r\ny", doc.root.getString("b").?);
    try testing.expectEqualStrings("x\r\ny", doc.root.getString("l").?);
}

/// `n` dotted segments: "a.a.a".
fn dottedKey(gpa: std.mem.Allocator, out: *std.ArrayList(u8), n: usize) !void {
    for (0..n) |i| try out.appendSlice(gpa, if (i == 0) "a" else ".a");
}

/// `before`, a key of `n` segments, `after`.
fn deepSource(n: usize, before: []const u8, after: []const u8) ![]u8 {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, before);
    try dottedKey(gpa, &out, n);
    try out.appendSlice(gpa, after);
    return out.toOwnedSlice(gpa);
}

test "max_key_depth bounds tables made by headers and dotted keys" {
    const gpa = testing.allocator;
    // Each form is `n` key segments deep in total, `fixed` of them in the text around the long key.
    const forms = [_]struct { before: []const u8, after: []const u8, fixed: usize }{
        .{ .before = "[", .after = "]", .fixed = 0 },
        .{ .before = "[[", .after = "]]", .fixed = 0 },
        .{ .before = "", .after = " = 1", .fixed = 0 },
        .{ .before = "x = {", .after = " = 1}", .fixed = 1 },
        .{ .before = "x = [{y = {", .after = " = 1}}]", .fixed = 2 },
        .{ .before = "[t.u]\n", .after = " = 1", .fixed = 2 },
        .{ .before = "[[t]]\nv = { w = 1 }\n", .after = " = 1", .fixed = 1 },
    };
    for (forms) |form| {
        errdefer std.debug.print("form: {s}...{s}\n", .{ form.before, form.after });
        const at_limit = try deepSource(128 - form.fixed, form.before, form.after);
        defer gpa.free(at_limit);
        try roundTrip(at_limit);
        for ([_]usize{ 129 - form.fixed, 100_000 }) |n| {
            const too_deep = try deepSource(n, form.before, form.after);
            defer gpa.free(too_deep);
            var diag: toml.Diagnostic = .{};
            try testing.expectError(error.LimitExceeded, toml.Document.parse(gpa, too_deep, .{}, &diag));
            try testing.expectEqualStrings("key nesting too deep", diag.message);
        }
    }
    // Sibling keys and later sections do not add up.
    try expectValid("[a.b]\nc.d = 1\ne.f = { g.h = 1, i.j = 2 }\n[k]\nl = 1\n");
    var raised = try toml.Document.parse(gpa, "a.b.c = 1", .{ .max_key_depth = 3 }, null);
    raised.deinit();
    try testing.expectError(error.LimitExceeded, toml.Document.parse(gpa, "a.b.c = 1", .{ .max_key_depth = 2 }, null));
}

test "writer: a tree too deep to write is an error, not a stack overflow" {
    const gpa = testing.allocator;
    var doc = try toml.Document.init(gpa);
    defer doc.deinit();
    const path = try gpa.alloc([]const u8, 100_000);
    defer gpa.free(path);
    @memset(path, "a");
    try doc.set(path, .{ .integer = 1 });
    try testing.expectError(error.NestingTooDeep, doc.toOwnedString(gpa));

    // The same through arrays, and a table that contains itself.
    var arrays = try toml.Document.init(gpa);
    defer arrays.deinit();
    var v: toml.Value = .{ .integer = 1 };
    for (0..100_000) |_| {
        const arr = try arrays.allocator().create(toml.Array);
        arr.* = .{};
        try arr.items.append(arrays.allocator(), v);
        v = .{ .array = arr };
    }
    try arrays.set(&.{"deep"}, v);
    try testing.expectError(error.NestingTooDeep, arrays.toOwnedString(gpa));

    var cycle = try toml.Document.init(gpa);
    defer cycle.deinit();
    try cycle.set(&.{"self"}, .{ .table = cycle.root });
    try testing.expectError(error.NestingTooDeep, cycle.toOwnedString(gpa));
}

// ---- writing and round trips ---------------------------------------------

test "writer: exact output for every value type and every escape" {
    const src =
        \\s = "q\" b\\ n\n r\r t\t \b \f \u0000 \u001F \u007F é"
        \\"" = "empty key"
        \\"a b" = -9223372036854775808
        \\max = 9223372036854775807
        \\yes = true
        \\no = false
        \\f = -0.0
        \\big = 1e300
        \\small = 1.5e-7
        \\whole = 3.0
        \\specials = [inf, -inf, nan]
        \\odt = 1979-05-27T07:32:00.000000001-07:30
        \\utc = 1979-05-27T07:32:00+00:00
        \\ldt = 1979-05-27T07:32:00
        \\ld = 0001-01-01
        \\lt = 07:32:00.5
        \\arr = [[], [1, ["x"]], {}, { a = { b = 2 } }]
        \\
    ;
    var doc = try parseOk(src);
    defer doc.deinit();
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\s = "q\" b\\ n\n r\r t\t \b \f \u0000 \u001F \u007F é"
        \\"" = "empty key"
        \\"a b" = -9223372036854775808
        \\max = 9223372036854775807
        \\yes = true
        \\no = false
        \\f = -0.0
        \\big = 1e300
        \\small = 1.5e-7
        \\whole = 3.0
        \\specials = [inf, -inf, nan]
        \\odt = 1979-05-27T07:32:00.000000001-07:30
        \\utc = 1979-05-27T07:32:00Z
        \\ldt = 1979-05-27T07:32:00
        \\ld = 0001-01-01
        \\lt = 07:32:00.5
        \\arr = [[], [1, ["x"]], {}, { a = { b = 2 } }]
        \\
    , out);
    try roundTrip(src);
}

fn roundTrip(src: []const u8) !void {
    var a = try parseOk(src);
    defer a.deinit();
    const text = try a.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    var diag: toml.Diagnostic = .{};
    var b = toml.Document.parse(testing.allocator, text, .{}, &diag) catch |e| {
        std.debug.print("re-parse failed ({f}) for output:\n{s}\n", .{ diag, text });
        return e;
    };
    defer b.deinit();
    // The writer must not lose or change anything.
    try expectSameTree(a.root, b.root);
    const text2 = try b.toOwnedString(testing.allocator);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "writer: round trips preserve structure" {
    try roundTrip("a = 1e-7\nb = 123456789012345680.0\nc = 5e-324\nd = 0.0001\n");
    try roundTrip(
        \\title = "x"
        \\n = 5
        \\f = 1.5
        \\whole = 3.0
        \\big = 1e300
        \\neg = -0.0
        \\s = "line\nbreak \"q\" \\ \u0001 é"
        \\d = 1979-05-27T07:32:00.5-07:00
        \\arr = [1, [2, 3], { a = 1 }]
        \\inl = { x = 1, "y z" = { q = true } }
        \\"odd key" = 1
        \\[a.b]
        \\c = 1
        \\[a.b.d]
        \\e = 2
        \\[[list]]
        \\n = 1
        \\[list.sub]
        \\z = 1
        \\[[list]]
        \\n = 2
        \\[x.y.z]
        \\only = "leaf"
    );
}

test "writer: output is as expected for a simple document" {
    var doc = try parseOk("b = 1\na = \"s\"\n[t]\nk = true\n[[arr]]\nx = 1\n[[arr]]\nx = 2\n");
    defer doc.deinit();
    const text = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "b = 1\na = \"s\"\n\n[t]\nk = true\n\n[[arr]]\nx = 1\n\n[[arr]]\nx = 2\n",
        text,
    );
}

test "writer: dotted keys stay dotted keys" {
    try roundTrips("a.b.c.d = 1\n");
    try roundTrips(
        \\# about the name
        \\physical.color = "orange" # tail
        \\physical.shape.kind = "round"
        \\name = "x"
        \\
        \\[fruit]
        \\apple.color = "red"
        \\apple.taste.sweet = true
        \\
        \\[fruit.apple.texture]
        \\smooth = true
        \\
        \\[[list]]
        \\a.b = 1
        \\
        \\[list.a.c]
        \\d = 2
        \\
    );
    try roundTrips("x = { a.b = 1, a.c.d = 2, e = [{ f.g = 3 }] }\n");
}

test "writer: output does not grow faster than the input" {
    const gpa = testing.allocator;
    for ([_][2][]const u8{ .{ "", " = 1\n" }, .{ "x = { ", " = 1 }\n" } }) |form| {
        const src = try deepSource(120, form[0], form[1]);
        defer gpa.free(src);
        var doc = try parseOk(src);
        defer doc.deinit();
        const out = try doc.toOwnedString(gpa);
        defer gpa.free(out);
        // Only the spaces around "=" and braces may differ.
        try testing.expect(out.len <= src.len + 4);
    }
}

test "writer: a dotted table that needs a header still gets one" {
    // Header comments can only be written on a [header] line.
    var doc = try parseOk("a.b.c = 1\nd = 2\n");
    defer doc.deinit();
    try doc.setComments(&.{ "a", "b" }, .{ .after = "# about b" });
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("d = 2\n\n[a.b] # about b\nc = 1\n", out);
    try roundTrip(out);

    // An emptied dotted table is still part of the tree.
    var emptied = try parseOk("a.b = 1\ne.f.g = 2\n");
    defer emptied.deinit();
    try testing.expect(emptied.root.getTable("a").?.remove("b"));
    try testing.expect(emptied.root.getTable("e").?.getTable("f").?.remove("g"));
    const text = try emptied.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    var again = try parseOk(text);
    defer again.deinit();
    try expectSameTree(emptied.root, again.root);
}

test "writer: an implicit table gets a header once it holds a dotted key" {
    var doc = try parseOk("[a.b]\n");
    defer doc.deinit();
    var dotted = try parseOk("c.d = 1\n");
    defer dotted.deinit();
    // Move the dotted table into the implicit table `a`.
    try doc.set(&.{ "a", "c" }, dotted.root.get("c").?);
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[a]\nc.d = 1\n\n[a.b]\n", out);
}

fn expectUnwritable(doc: *const toml.Document, want: anyerror) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expectError(want, doc.write(testing.allocator, &aw.writer));
    // Refused before any output, so a half-written file is never produced.
    try testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "writer: refuses values that would not read back" {
    const date: toml.Date = .{ .year = 2024, .month = 1, .day = 1 };
    const time: toml.Time = .{ .hour = 1, .minute = 2, .second = 3 };
    const bad = [_]toml.Value{
        .{ .string = "\xff" },
        .{ .string = "cut \xe2\x82" },
        .{ .datetime = .{} },
        .{ .datetime = .{ .offset_minutes = 0 } },
        .{ .datetime = .{ .date = date, .offset_minutes = 0 } },
        .{ .datetime = .{ .time = time, .offset_minutes = 0 } },
        .{ .datetime = .{ .date = date, .time = time, .offset_minutes = 24 * 60 } },
        .{ .datetime = .{ .date = date, .time = time, .offset_minutes = -24 * 60 } },
        .{ .datetime = .{ .date = .{ .year = 10000, .month = 1, .day = 1 } } },
        .{ .datetime = .{ .date = .{ .year = 2024, .month = 0, .day = 1 } } },
        .{ .datetime = .{ .date = .{ .year = 2024, .month = 13, .day = 1 } } },
        .{ .datetime = .{ .date = .{ .year = 2024, .month = 1, .day = 0 } } },
        .{ .datetime = .{ .date = .{ .year = 2023, .month = 2, .day = 29 } } },
        .{ .datetime = .{ .time = .{ .hour = 24, .minute = 0, .second = 0 } } },
        .{ .datetime = .{ .time = .{ .hour = 0, .minute = 60, .second = 0 } } },
        .{ .datetime = .{ .time = .{ .hour = 0, .minute = 0, .second = 61 } } },
    };
    for (bad) |v| {
        var doc = try parseOk("first = 1\n");
        defer doc.deinit();
        try doc.set(&.{ "t", "v" }, v);
        try expectUnwritable(&doc, error.InvalidValue);
        // Also inside an array and an inline table.
        const arr = try doc.allocator().create(toml.Array);
        arr.* = .{};
        try arr.items.append(doc.allocator(), v);
        try doc.set(&.{ "t", "v" }, .{ .array = arr });
        try expectUnwritable(&doc, error.InvalidValue);
    }

    var key = try parseOk("first = 1\n");
    defer key.deinit();
    try key.set(&.{"\xff"}, .{ .integer = 1 });
    try expectUnwritable(&key, error.InvalidValue);
}

test "writer: values that used to panic are errors" {
    const nanos: toml.Datetime = .{ .time = .{ .hour = 1, .minute = 1, .second = 1, .nanosecond = 1_000_000_000 } };
    var buf: [64]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, std.fmt.bufPrint(&buf, "{f}", .{nanos}));
    var doc = try toml.Document.init(testing.allocator);
    defer doc.deinit();
    try doc.set(&.{"a"}, .{ .datetime = nanos });
    try expectUnwritable(&doc, error.InvalidValue);

    // An array of tables holding something else, first and last.
    for ([_]bool{ true, false }) |table_first| {
        var mixed = try parseOk("[[a]]\nb = 1\n");
        defer mixed.deinit();
        const list = mixed.root.getArray("a").?;
        try list.items.insert(mixed.allocator(), if (table_first) 1 else 0, .{ .integer = 1 });
        try expectUnwritable(&mixed, error.InvalidValue);
        if (table_first) {
            try testing.expectError(error.NotFound, mixed.setComments(&.{"a"}, .{ .after = "# x" }));
            try testing.expectError(error.NotFound, mixed.setComments(&.{ "a", "b" }, .{ .after = "# x" }));
        }
    }
}

test "writer: comment fields cannot inject TOML" {
    const bad = [_][]const u8{ "injected = true", "# a\ninjected = true", "# a\rb", "# \xff", "  " };
    for (bad) |line| {
        errdefer std.debug.print("comment: {f}\n", .{std.zig.fmtString(line)});
        // Each way of storing a comment that skips `setComments`.
        for (0..5) |where| {
            var doc = try parseOk("a = 1\n[t]\nb = 2\n");
            defer doc.deinit();
            const lines = try doc.allocator().dupe([]const u8, &.{line});
            const t = doc.root.getTable("t").?;
            switch (where) {
                0 => doc.root.footer = lines,
                1 => t.header = .{ .before = lines },
                2 => t.header = .{ .after = line },
                3 => try t.key_comments.put(doc.allocator(), "b", .{ .before = lines }),
                else => try t.key_comments.put(doc.allocator(), "b", .{ .after = line }),
            }
            try expectUnwritable(&doc, error.InvalidValue);
        }
    }
    var doc = try parseOk("a = 1\n");
    defer doc.deinit();
    try testing.expectError(error.InvalidComment, doc.setComments(&.{"a"}, .{ .after = "# \xff" }));
    try testing.expectError(error.InvalidComment, doc.setComments(&.{"a"}, .{ .before = &.{"# \xc0\x80"} }));
    try doc.setComments(&.{"a"}, .{ .before = &.{ "  # indented", "" }, .after = "# caf\u{e9}\ttab" });
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try roundTrip(out);
}

test "writer: floats always look like floats" {
    var doc = try parseOk("a = 3.0\nb = 1e22\nc = inf\nd = -inf\ne = nan\n");
    defer doc.deinit();
    const text = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    var re = try parseOk(text);
    defer re.deinit();
    try testing.expect(re.root.get("a").? == .float);
    try testing.expect(re.root.get("b").? == .float);
    try testing.expectEqual(@as(f64, 1e22), re.root.getFloat("b").?);
}

test "building and editing a document" {
    var doc = try toml.Document.init(testing.allocator);
    defer doc.deinit();
    try doc.set(&.{ "panel", "position" }, .{ .string = try doc.dupe("bottom") });
    try doc.set(&.{ "panel", "auto_hide" }, .{ .boolean = false });
    try doc.set(&.{ "appearance", "accent" }, .{ .string = try doc.dupe("#3a6ea5") });
    try testing.expectError(error.NotATable, doc.set(&.{ "panel", "position", "x" }, .{ .integer = 1 }));
    const text = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "[panel]\nposition = \"bottom\"\nauto_hide = false\n\n[appearance]\naccent = \"#3a6ea5\"\n",
        text,
    );
}

test "overwriting a value with set does not grow the document" {
    var doc = try toml.Document.init(testing.allocator);
    defer doc.deinit();
    const key: []const u8 = rep("k", 1000);
    try doc.set(&.{ "t", key }, .{ .integer = 0 });
    const before = doc.arena.queryCapacity();
    for (0..10_000) |i| try doc.set(&.{ "t", key }, .{ .integer = @intCast(i) });
    try testing.expectEqual(before, doc.arena.queryCapacity());
    try testing.expectEqual(@as(i64, 9999), doc.root.getTable("t").?.getInt(key).?);
}

test "editing a parsed document keeps unknown keys" {
    var doc = try parseOk("[panel]\nposition = \"top\"\nfuture_key = [1, 2]\n[other]\nx = 1\n");
    defer doc.deinit();
    try doc.set(&.{ "panel", "position" }, .{ .string = try doc.dupe("bottom") });
    const text = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("[panel]\nposition = \"bottom\"\nfuture_key = [1, 2]\n\n[other]\nx = 1\n", text);
}

test "no leaks on error paths" {
    // testing.allocator reports leaks; each of these fails part-way through parsing.
    const bad = [_][]const u8{
        "a = [1, 2",
        "[a]\nb = { c = 1, c = 2 }",
        "a = \"abc",
        "[[a]]\n[a]",
    };
    for (bad) |src| try expectInvalid(src);
}

fn parseOnce(gpa: std.mem.Allocator, src: []const u8) !void {
    var doc = try toml.Document.parse(gpa, src, .{}, null);
    doc.deinit();
}

/// Fails each allocation in turn, requiring `OutOfMemory` and no leak.
fn checkParseAllocations(src: []const u8) !void {
    try testing.checkAllAllocationFailures(testing.allocator, parseOnce, .{src});
}

test "allocation failure is handled" {
    try checkParseAllocations("a = [1, 2, { b = \"x\" }]\n[t.u]\nk = 1\n[[l]]\nz = 2\n");

    // Enough keys, tables and long strings that the arena has to grow often.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for (0..40) |i| {
        try src.print(testing.allocator,
            \\k{d} = "{s}"
            \\a{d}.b.c = [1.5, 1979-05-27T07:32:00Z, {{ d = 'e' }}]
            \\
        , .{ i, rep("s", 200), i });
    }
    for (0..40) |i| try src.print(testing.allocator, "[[list.sub{d}]]\nv = {d}\n", .{ i % 3, i });
    try checkParseAllocations(src.items);
}

test "allocation failure while converting a number is OutOfMemory, not Syntax" {
    // Numbers long enough that converting them has to ask for memory.
    try checkParseAllocations("a = 1." ++ rep("0", 100_000));
    try checkParseAllocations("a = 1.0_" ++ rep("0", 100_000));
    try checkParseAllocations("a = 0x" ++ rep("0_", 50_000) ++ "1");
}

fn editAndWrite(gpa: std.mem.Allocator) !void {
    var doc = try toml.Document.parse(gpa, "# c\na = 1 # t\n[s.t]\nk = [1]\n# end\n", .{}, null);
    defer doc.deinit();
    try doc.set(&.{ "new", "deep", "key" }, .{ .string = try doc.dupe(rep("v", 5000)) });
    try doc.set(&.{"a"}, .{ .integer = 2 });
    try doc.setComments(&.{ "s", "t", "k" }, .{ .before = &.{ "# one", "", "# two" }, .after = "# three" });
    const out = try doc.toOwnedString(gpa);
    gpa.free(out);
}

fn buildAndWrite(gpa: std.mem.Allocator) !void {
    var doc = try toml.Document.init(gpa);
    defer doc.deinit();
    var name: [8]u8 = undefined;
    for (0..40) |i| {
        const key = try std.fmt.bufPrint(&name, "k{d}", .{i});
        try doc.set(&.{ "a", "b", "c", key }, .{ .integer = 1 });
        try doc.root.setComments(doc.allocator(), try doc.dupe(key), .{ .after = "# x" });
    }
    const out = try doc.toOwnedString(gpa);
    gpa.free(out);
}

test "allocation failure while editing and writing is handled" {
    // `Allocating` writers report a failed allocation as `WriteFailed`.
    const run = struct {
        fn edit(gpa: std.mem.Allocator) !void {
            editAndWrite(gpa) catch |e| return asOom(e);
        }
        fn build(gpa: std.mem.Allocator) !void {
            buildAndWrite(gpa) catch |e| return asOom(e);
        }
        fn asOom(e: anyerror) anyerror {
            return if (e == error.WriteFailed) error.OutOfMemory else e;
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, run.edit, .{});
    try testing.checkAllAllocationFailures(testing.allocator, run.build, .{});
}

test "tables on a dotted or header path reserve room for one entry" {
    var doc = try parseOk("a.b.c = 1\n[d.e.f]\n");
    defer doc.deinit();
    const a = doc.root.getTable("a").?; // dotted
    const d = doc.root.getTable("d").?; // implicit
    for ([_]*toml.Table{ a, a.getTable("b").?, d, d.getTable("e").? }) |t| {
        try testing.expectEqual(@as(usize, 1), t.entries.capacity());
    }
}

test "a limiting allocator bounds the memory a parse can use" {
    // What the documentation tells callers to do with untrusted input.
    var buffer: [64 * 1024]u8 = undefined;
    var limited: std.heap.FixedBufferAllocator = .init(&buffer);
    try testing.expectError(error.OutOfMemory, toml.Document.parse(limited.allocator(), rep("[[a]]\n", 5000), .{}, null));
}

test "parseReader reads from a std.Io.Reader and enforces max_bytes" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("a = 1\n[t]\nb = \"x\"\n");
    var doc = try toml.Document.parseReader(gpa, &r, .{}, null);
    defer doc.deinit();
    try std.testing.expectEqual(@as(i64, 1), doc.root.lookup("a").?.integer);

    var big: std.Io.Reader = .fixed("a = 1\n");
    try std.testing.expectError(error.LimitExceeded, toml.Document.parseReader(gpa, &big, .{ .max_bytes = 3 }, null));
}

// ---- TOML 1.1.0 -----------------------------------------------------------
// Grammar: https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf

test "1.1: inline tables may span lines, hold comments and end with a comma" {
    const src =
        \\a = {
        \\    x = 1, # first
        \\    y = { z = [1,
        \\        2] },
        \\
        \\}
        \\b = { k = "v", }
        \\c = {
        \\}
        \\d = { # only a comment
        \\}
        \\
    ;
    try expectOnly11(src);
    var doc = try parseWith(V11, src);
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.root.lookup("a.x").?.integer);
    try testing.expectEqual(@as(i64, 2), doc.root.lookup("a.y").?.table.getArray("z").?.items.items[1].integer);
    try testing.expectEqualStrings("v", doc.root.lookup("b.k").?.string);
    try testing.expectEqual(@as(usize, 0), doc.root.getTable("c").?.count());
    try testing.expectEqual(@as(usize, 0), doc.root.getTable("d").?.count());
}

test "1.1: inline tables still reject malformed separators" {
    try expectInvalid("a = { , }");
    try expectInvalid("a = { x = 1,, }");
    try expectInvalid("a = { x = 1 y = 2 }");
    try expectInvalid("a = { x = 1,\n");
    try expectInvalid("a = { x = 1, x = 2 }");
    try expectInvalid("a = { x = 1,\n y }");
}

test "1.1: \\e and \\xHH escapes" {
    try expectOnly11("a = \"\\e[0m\"");
    try expectOnly11("a = \"\\x61\"");
    var doc = try parseWith(V11,
        \\a = "csi: \e["
        \\b = "null: \x00, a: \x61, ÿ: \xFF"
        \\c = """
        \\multi \e \x41"""
        \\d = 'literal \e \x41 stays literal'
        \\
    );
    defer doc.deinit();
    try testing.expectEqualStrings("csi: \x1b[", doc.root.getString("a").?);
    try testing.expectEqualStrings("null: \x00, a: a, \xc3\xbf: \xc3\xbf", doc.root.getString("b").?);
    try testing.expectEqualStrings("multi \x1b A", doc.root.getString("c").?);
    try testing.expectEqualStrings("literal \\e \\x41 stays literal", doc.root.getString("d").?);
}

test "1.1: malformed \\x escapes are rejected" {
    try expectInvalid("a = \"\\x6\"");
    try expectInvalid("a = \"\\xZZ\"");
    try expectInvalid("a = \"\\x\"");
    try expectInvalid("a = \"\\x+1\"");
    try expectInvalid("a = \"\\E\"");
}

test "1.1: seconds are optional in times and datetimes" {
    try expectOnly11("a = 07:32");
    try expectOnly11("a = 1979-05-27 07:32Z");
    try expectOnly11("a = 1979-05-27T07:32");
    try expectOnly11("a = 1979-05-27T07:32-05:00");
    var doc = try parseWith(V11,
        \\lt = 07:32
        \\odt = 1979-05-27 07:32Z
        \\ldt = 1979-05-27T07:32
        \\off = 1979-05-27T07:32-05:30
        \\full = 07:32:10.5
        \\
    );
    defer doc.deinit();
    const lt = doc.root.get("lt").?.datetime.time.?;
    try testing.expectEqual(@as(u8, 7), lt.hour);
    try testing.expectEqual(@as(u8, 32), lt.minute);
    try testing.expectEqual(@as(u8, 0), lt.second);
    try testing.expectEqual(@as(i16, 0), doc.root.get("odt").?.datetime.offset_minutes.?);
    try testing.expect(doc.root.get("ldt").?.datetime.offset_minutes == null);
    try testing.expectEqual(@as(i16, -330), doc.root.get("off").?.datetime.offset_minutes.?);
    try testing.expectEqual(@as(u32, 500_000_000), doc.root.get("full").?.datetime.time.?.nanosecond);
}

test "1.1: optional seconds do not loosen the rest of the time grammar" {
    try expectInvalid("a = 07:3");
    try expectInvalid("a = 7:32");
    try expectInvalid("a = 07:32.5"); // a fraction needs seconds
    try expectInvalid("a = 1979-05-27T07:32.5Z");
    try expectInvalid("a = 07:32Z"); // a bare time has no offset
    try expectInvalid("a = 24:00");
    try expectInvalid("a = 07:60");
    try expectInvalid("a = 1979-05-27T07:32:");
}

test "1.1: version defaults to 1.1" {
    var doc = try toml.Document.parse(testing.allocator, "a = 07:32\nb = \"\\e\"\n", .{}, null);
    doc.deinit();
    try testing.expectEqual(toml.Version.v1_1, (toml.Options{}).version);
}

// ---- comment preservation ----------------------------------------------

/// Parse, write, and require the text to come back unchanged; then once more
/// to show it is a fixed point.
fn roundTrips(src: []const u8) !void {
    var doc = try parseOk(src);
    defer doc.deinit();
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "comments survive a round trip" {
    try roundTrips(
        \\# Settings for the panel.
        \\# Edit with care.
        \\
        \\# where it sits
        \\position = "top" # or "bottom"
        \\size = 12
        \\
        \\# the clock
        \\[clock] # header note
        \\# 24 hour?
        \\military = true
        \\
        \\# first entry
        \\[[items]]
        \\name = "a" # one
        \\
        \\[[items]]
        \\# second
        \\name = "b"
        \\
        \\# the end
        \\
    );
}

test "a comment moves with its key when the writer reorders" {
    var doc2 = try parseOk("# about a\na = 1 # a!\n[s]\nb = 2\n");
    defer doc2.deinit();
    try doc2.set(&.{"c"}, .{ .integer = 3 });
    const out = try doc2.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# about a\na = 1 # a!\nc = 3\n\n[s]\nb = 2\n", out);
}

test "editing a value keeps its comments; removing the key drops them" {
    var doc = try parseOk("# keep\nk = 1 # me\nj = 2 # gone\n");
    defer doc.deinit();
    try doc.set(&.{"k"}, .{ .integer = 5 });
    try testing.expect(doc.root.remove("j"));
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# keep\nk = 5 # me\n", out);
}

test "setComments on keys and headers" {
    var doc = try parseOk("a = 1\n[t]\nb = 2\n");
    defer doc.deinit();
    try doc.setComments(&.{"a"}, .{ .before = &.{"# about a"}, .after = "# note" });
    try doc.setComments(&.{"t"}, .{ .before = &.{ "", "# table t" } });
    try doc.setComments(&.{ "t", "b" }, .{ .after = "# b" });
    try testing.expectError(error.NotFound, doc.setComments(&.{"zz"}, .{ .after = "# x" }));
    try testing.expectError(error.InvalidComment, doc.setComments(&.{"a"}, .{ .after = "no hash" }));
    try testing.expectError(error.InvalidComment, doc.setComments(&.{"a"}, .{ .before = &.{"# a\nb = 1"} }));
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# about a\na = 1 # note\n\n# table t\n[t]\nb = 2 # b\n", out);
    // Clearing them again.
    try doc.setComments(&.{"a"}, .{});
    try testing.expect(doc.root.commentsOf("a") == null);
}

fn expectOutput(doc: *const toml.Document, want: []const u8) !void {
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(want, out);
    try roundTrip(out);
}

fn emptyTable(doc: *toml.Document) !*toml.Table {
    const t = try doc.allocator().create(toml.Table);
    t.* = .{};
    return t;
}

test "writer: no blank line at the top, and none added before the footer" {
    try roundTrips("a = 1\n# end\n");
    try roundTrips("a = 1\n\n# end\n");

    // Reordering moves `[a]`, and the blank line above it, to the top.
    var moved = try parseOk("[[a.b]]\n\n[a]\n");
    defer moved.deinit();
    try expectOutput(&moved, "[a]\n\n[[a.b]]\n");

    // So does removing what came before: a header, a key, or the footer.
    var header = try parseOk("a = 1\n\n# t\n[t]\n");
    defer header.deinit();
    _ = header.root.remove("a");
    try expectOutput(&header, "# t\n[t]\n");
    var key = try parseOk("a = 1\n\nb = 2\n");
    defer key.deinit();
    _ = key.root.remove("a");
    try expectOutput(&key, "b = 2\n");
    var footer = try parseOk("a = 1\n\n# end\n");
    defer footer.deinit();
    _ = footer.root.remove("a");
    try expectOutput(&footer, "# end\n");
}

test "writer: an emptied implicit table is not dropped" {
    var doc = try parseOk("[a.b]\n[c.d.e]\n");
    defer doc.deinit();
    try testing.expect(doc.root.getTable("a").?.remove("b"));
    try testing.expect(doc.root.getTable("c").?.getTable("d").?.remove("e"));
    try expectOutput(&doc, "[a]\n\n[c.d]\n");
}

test "setComments on an implicit table makes the writer give it a header" {
    var doc = try parseOk("[a.b]\nx = 1\n");
    defer doc.deinit();
    try doc.setComments(&.{"a"}, .{ .after = "# hello" });
    try expectOutput(&doc, "[a] # hello\n\n[a.b]\nx = 1\n");
}

test "setComments refuses places that cannot hold a comment" {
    var doc = try parseOk("a = { b = 1, c.d = 2 }\nlist = [1]\n");
    defer doc.deinit();
    for ([_][]const []const u8{ &.{ "a", "b" }, &.{ "a", "c" }, &.{ "a", "c", "d" } }) |path| {
        try testing.expectError(error.CommentsNotSupported, doc.setComments(path, .{ .after = "# x" }));
        try testing.expectError(error.CommentsNotSupported, doc.setComments(path, .{ .before = &.{"# x"} }));
    }
    try testing.expectError(error.NotFound, doc.setComments(&.{ "a", "zz" }, .{ .after = "# x" }));
    // The inline table's own line can hold them.
    try doc.setComments(&.{"a"}, .{ .after = "# ok" });
    try expectOutput(&doc, "a = { b = 1, c.d = 2 } # ok\nlist = [1]\n");
}

test "comments stay with a key whose value changes between scalar and table" {
    // Scalar to table, and to an array of tables.
    var doc = try parseOk("# doc for k\nk = 1 # tail\n");
    defer doc.deinit();
    try doc.set(&.{"k"}, .{ .table = try emptyTable(&doc) });
    try expectOutput(&doc, "# doc for k\n[k] # tail\n");
    const list = try doc.allocator().create(toml.Array);
    list.* = .{ .is_table_array = true };
    try list.items.append(doc.allocator(), .{ .table = try emptyTable(&doc) });
    try list.items.append(doc.allocator(), .{ .table = try emptyTable(&doc) });
    try doc.set(&.{"k"}, .{ .array = list });
    try expectOutput(&doc, "# doc for k\n[[k]] # tail\n\n[[k]]\n");
    // And back.
    try doc.set(&.{"k"}, .{ .integer = 2 });
    try expectOutput(&doc, "# doc for k\nk = 2 # tail\n");

    // Section to scalar, to another section, and to an inline table.
    var section = try parseOk("# about t\n[t] # head\nx = 1\n");
    defer section.deinit();
    try section.set(&.{"t"}, .{ .table = try emptyTable(&section) });
    try expectOutput(&section, "# about t\n[t] # head\n");
    try section.set(&.{"t"}, .{ .integer = 3 });
    try expectOutput(&section, "# about t\nt = 3 # head\n");

    // Setting the new comments replaces the carried ones, and clearing them
    // does not bring the old ones back.
    try section.set(&.{"t"}, .{ .table = try emptyTable(&section) });
    try section.setComments(&.{"t"}, .{ .after = "# new" });
    try expectOutput(&section, "[t] # new\n");
    try section.setComments(&.{"t"}, .{});
    try expectOutput(&section, "[t]\n");

    // A dotted table moved onto a commented key keeps the comment too.
    var dotted = try parseOk("# about k\nk = 1\n");
    defer dotted.deinit();
    var from = try parseOk("k.a = 1\n");
    defer from.deinit();
    try dotted.set(&.{"k"}, from.root.get("k").?);
    try expectOutput(&dotted, "# about k\n[k]\na = 1\n");
}

test "Table.setComments does not keep the caller's key" {
    var doc = try parseOk("a = 1\n");
    defer doc.deinit();
    var key = "later".*;
    // Comments may be set before the value; they apply once it exists.
    try doc.root.setComments(doc.allocator(), &key, .{ .after = "# first" });
    try doc.root.setComments(doc.allocator(), &key, .{ .after = "# second" });
    @memset(&key, 'x'); // the caller reuses its buffer
    try testing.expectEqualStrings("# second", doc.root.commentsOf("later").?.after.?);
    try doc.set(&.{"later"}, .{ .integer = 2 });
    try expectOutput(&doc, "a = 1\nlater = 2 # second\n");
}

test "a comment-only document and CRLF line endings keep their comments" {
    try roundTrips("# just a comment\n");
    var doc = try parseOk("# c\r\nk = 1 # t\r\n");
    defer doc.deinit();
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# c\nk = 1 # t\n", out);
}

test "allocation failure while parsing comments is handled" {
    try checkParseAllocations("# a\nk = 1 # b\n\n# c\n[t] # d\nx = 2\n# end\n");
    try checkParseAllocations("# " ++ rep("long comment ", 500) ++ "\nk = 1 # " ++ rep("tail ", 1000) ++ "\n");
}
