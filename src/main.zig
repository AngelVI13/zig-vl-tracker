const std = @import("std");
const xml = @import("xml.zig");

const re = @cImport(@cInclude("regez.h"));
const REGEX_T_ALIGNOF = re.sizeof_regex_t;
const REGEX_T_SIZEOF = re.alignof_regex_t;

const mem = std.mem;
const Allocator = mem.Allocator;

const root_dir = "src";
const master_xml = root_dir ++ "/" ++ "master_cleaning.xml";
const megabyte = 1024 * 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var xml_text = try readFile(master_xml);

    const xml_document = try xml.parse(alloc, xml_text);
    defer xml_document.deinit();

    var list = try getProtocolsFromXml(alloc, xml_document.root);
    std.debug.print("list len: {d}\n", .{list.len});

    var result = try getTestsFromDir(alloc, "src");
    std.debug.print("passed: {s}\nfailed: {s}\n", .{ result.passed, result.failed });
}

const ReadFileError = error{
    FileTooBig,
};

pub fn readFile(filename: []const u8) ![]const u8 {
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    const buf_size = 1 * megabyte;
    var buf: [buf_size]u8 = undefined;
    var n = try in_stream.readAll(&buf);
    if (n >= buf_size) {
        return error.FileTooBig;
    }

    return buf[0..n];
}

pub fn getProtocolsFromXml(alloc: Allocator, root: *xml.Element) ![]xml.Element {
    // TODO: should it be *xml.Element
    var list = std.ArrayList(xml.Element).init(alloc);
    defer list.deinit();

    try root.allElements(&list, "protocol");

    return list.toOwnedSlice();
}

pub const GetTestsFromDirResult = struct {
    passed: []const []const u8,
    failed: []const []const u8,
};

// TODO: Path parameter should be the CWD
pub fn getTestsFromDir(alloc: Allocator, path: []const u8) !GetTestsFromDirResult {
    var dir = try std.fs.cwd().openIterableDir(path, .{});
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // TODO: process filenames here
        std.debug.print("{s} {s}\n", .{ entry.basename, entry.path });
    }

    var map = std.StringHashMap(u8).init(alloc);
    defer map.deinit();

    var passed = std.ArrayList([]const u8).init(alloc);
    defer passed.deinit();

    var failed = std.ArrayList([]const u8).init(alloc);
    defer failed.deinit();

    // try map.put(1600, .{ .x = 4, .y = -1 });
    // try expect(map.count() == 4);
    // var sum = Point{ .x = 0, .y = 0 };
    // var iterator = map.iterator();
    // while (iterator.next()) |entry| {
    //     sum.x += entry.value_ptr.x;
    //     sum.y += entry.value_ptr.y;
    // }

    return GetTestsFromDirResult{
        .passed = try passed.toOwnedSlice(),
        .failed = try failed.toOwnedSlice(),
    };
}

test "parse protocol xml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    const test_xml =
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<ta-tool-export>
        \\    <dv-plan project-id="PROJECT_ID" id="ID">
        \\        <build-result>PROJECT_ID:BUILD_RESULT_ID</build-result>
        \\        <verification-loop>LOOP_ID</verification-loop>
        \\        <protocols>
        \\            <protocol project-id="PROJECT_ID" id="PROTOCOL1_ID">
        \\                <test-script-reference>http://url.to.script1.py</test-script-reference>
        \\            </protocol>
        \\            <protocol project-id="PROJECT_ID" id="PROTOCOL2_ID">
        \\                <test-script-reference>http://url.to.script2.py</test-script-reference>
        \\            </protocol>
        \\        </protocols>
        \\    </dv-plan>
        \\</ta-tool-export>
    ;

    const document = try xml.parse(allocator, test_xml);
    defer document.deinit();

    const root = document.root;
    try std.testing.expect(std.mem.eql(u8, root.tag, "ta-tool-export"));

    var list = std.ArrayList(xml.Element).init(std.testing.allocator);
    defer list.deinit();

    try root.allElements(&list, "protocol");

    for (list.items, 0..) |elem, idx| {
        std.debug.print("{d} {} {s}\n", .{ idx, @TypeOf(elem), elem.tag });

        if (elem.getAttribute("id")) |id| {
            std.debug.print("{s}\n", .{id});
        }
    }

    try std.testing.expect(root.children.len == 1);
}

test "regex simple pattern match" {
    const allocator = std.testing.allocator;

    var slice = try allocator.alignedAlloc(u8, REGEX_T_ALIGNOF, REGEX_T_SIZEOF);
    const regex = @ptrCast(*re.regex_t, slice.ptr);
    defer allocator.free(@ptrCast([*]u8, regex)[0..REGEX_T_SIZEOF]);

    const result = re.regcomp(regex, "[ab]c", re.REG_EXTENDED | re.REG_ICASE);
    defer re.regfree(regex); // IMPORTANT!!

    try std.testing.expect(result == 0);

    // prints true
    std.debug.print("{any}\n", .{re.isMatch(regex, "ac")});

    // prints false
    std.debug.print("{any}\n", .{re.isMatch(regex, "nope")});

    std.testing.expect(true, re.isMatch(regex, "ac"));
    std.testing.expect(false, re.isMatch(regex, "nope"));
}

test "regex complex pattern match" {
    const allocator = std.testing.allocator;

    var slice = try allocator.alignedAlloc(u8, REGEX_T_ALIGNOF, REGEX_T_SIZEOF);
    const regex = @ptrCast(*re.regex_t, slice.ptr);
    defer allocator.free(@ptrCast([*]u8, regex)[0..REGEX_T_SIZEOF]);

    const result = re.regcomp(regex, "hello ?([[:alpha:]]*)", re.REG_EXTENDED | re.REG_ICASE);
    defer re.regfree(regex); // IMPORTANT!!

    try std.testing.expect(result == 0);

    const input = "hello Teg!";
    var matches: [5]re.regmatch_t = undefined;

    result = re.regexec(regex, input, matches.len, &matches, 0);
    try std.testing.expect(result == 0);

    for (matches, 0..) |m, i| {
        const start_offset = m.rm_so;
        if (start_offset == -1) break;

        const end_offset = m.rm_eo;

        const match = input[@intCast(usize, start_offset)..@intCast(usize, end_offset)];
        std.debug.print("matches[{d}] = {s}\n", .{ i, match });
    }
}
