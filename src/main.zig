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

const filename_pattern = "report_([a-zA-Z0-9]+-\\d+)_([A-Z]+)_.*";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var xml_text = try readFile(master_xml);

    const xml_document = try xml.parse(alloc, xml_text);
    defer xml_document.deinit();

    var list = try getProtocolsFromXml(alloc, xml_document.root);
    std.debug.print("list len: {d}\n", .{list.len});

    var re = try Regex.compile(alloc, filename_pattern);
    defer re.deinit();
    var result = try getTestsFromDir(alloc, &re, "src");
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
pub fn getTestsFromDir(alloc: Allocator, re: *Regex, path: []const u8) !GetTestsFromDirResult {
    var passedMap = std.StringHashMap(u8).init(alloc);
    // TODO: how to make the resize happen on .put instead of beforehand
    try passedMap.ensureTotalCapacity(1000);
    defer passedMap.deinit();

    var failedMap = std.StringHashMap(u8).init(alloc);
    // TODO: how to make the resize happen on .put instead of beforehand
    try failedMap.ensureTotalCapacity(1000);
    defer failedMap.deinit();

    var failedDuplicates = std.ArrayList([]const u8).init(alloc);
    defer failedDuplicates.deinit();

    var dir = try std.fs.cwd().openIterableDir(path, .{});
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const res = try getInfoFromFilename(re, entry.basename);
        if (res == null) {
            continue;
        }
        const result = res.?;

        if (std.mem.eql(u8, result.status, "PASS")) {
            if (passedMap.get(result.tc_id) == null) {
                try passedMap.put(result.tc_id, 0);
            }
        } else {
            if (failedMap.get(result.tc_id)) |_| {
                try failedDuplicates.append(result.tc_id);
            } else {
                try failedMap.put(result.tc_id, 0);
            }
        }
    }


    var failedThatPassed = std.ArrayList([]const u8).init(alloc);
    defer failedThatPassed.deinit();

    var passed = std.ArrayList([]const u8).init(alloc);
    defer passed.deinit();

    var failed = std.ArrayList([]const u8).init(alloc);
    defer failed.deinit();

    var failedKeyIterator = failedMap.keyIterator();
    while (failedKeyIterator.next()) |key| {
        if (passedMap.get(key.*)) |_| {
            try failedThatPassed.append(key.*);
            continue;
        }

        try failed.append(key.*);
    }

    std.debug.print("Failed TCs that later passed: {?}\n", .{failedThatPassed});
    std.debug.print("Failed Multiple Times: {?}\n", .{failedDuplicates});

    var passedKeyIterator = passedMap.keyIterator();
    while (passedKeyIterator.next()) |key| {
        try passed.append(key.*);
    }

    return GetTestsFromDirResult{
        .passed = try passed.toOwnedSlice(),
        .failed = try failed.toOwnedSlice(),
    };
}

const TestStatus = struct {
    tc_id: []const u8,
    status: []const u8, // TODO: make this into enum
};

fn getInfoFromFilename(re: *Regex, filename: []const u8) !?TestStatus {
    var captures = try re.captures(filename) orelse return null;
    defer captures.deinit();

    const tc_id = captures.sliceAt(1) orelse return null;
    const status = captures.sliceAt(2) orelse return null;

    return .{
        .tc_id = tc_id,
        .status = status,
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
    var re = try Regex.compile(std.testing.allocator, filename_pattern);
    defer re.deinit();

    const example_filename = "report_4AP2-38205_PASS_2022_04_19_17h_51m.xml";
    try std.testing.expect(try re.partialMatch(example_filename) == true);

    var captures = try re.captures(example_filename) orelse unreachable;
    defer captures.deinit();

    const tc_id = captures.sliceAt(1) orelse unreachable;
    try std.testing.expectEqualStrings(tc_id, "4AP2-38205");

    const status = captures.sliceAt(2) orelse unreachable;
    try std.testing.expectEqualStrings(status, "PASS");
}
