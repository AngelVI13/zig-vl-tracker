const std = @import("std");
const xml = @import("xml.zig");

// NOTE: clone this: https://github.com/tiehuis/zig-regex.git
// to ./include folder
const Regex = @import("regex").Regex;

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

pub fn getProtocolsFromXml(alloc: Allocator, root: *xml.Element) ![]*xml.Element {
    var list = std.ArrayList(*xml.Element).init(alloc);
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

    var passedMap = std.StringHashMap(u8).init(alloc);
    defer passedMap.deinit();

    var failedMap = std.StringHashMap(u8).init(alloc);
    defer failedMap.deinit();

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

    var list = std.ArrayList(*xml.Element).init(std.testing.allocator);
    defer list.deinit();

    try root.allElements(&list, "protocol");

    try std.testing.expect(list.items.len == 2);

    // for (list.items, 0..) |elem, idx| {
    //     std.debug.print("{d} {} {s}\n", .{ idx, @TypeOf(elem), elem.tag });

    //     if (elem.getAttribute("id")) |id| {
    //         std.debug.print("{s}\n", .{id});
    //     }
    // }
}

test "regex simple pattern match" {
    // const filename_pattern = "report_(?P<id>[a-zA-Z0-9]+-\\d+)_(?P<status>[A-Z]+)_.*";
    const filename_pattern = "report_([a-zA-Z0-9]+-\\d+)_([A-Z]+)_.*";
    var re = try Regex.compile(std.testing.allocator, filename_pattern);
    defer re.deinit();

    const example_filename = "report_4AP2-38205_PASS_2022_04_19_17h_51m.xml";
    try std.testing.expect(try re.partialMatch(example_filename) == true);

    var captures = try re.captures(example_filename) orelse unreachable;
    defer captures.deinit();

    const tc_id = captures.sliceAt(1) orelse unreachable;
    try std.testing.expectEqualStrings(tc_id, "4AP2-38205");
}

