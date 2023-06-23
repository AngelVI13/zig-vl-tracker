const std = @import("std");
const xml = @import("xml.zig");

// NOTE: clone this: https://github.com/tiehuis/zig-regex.git
// to ./include folder
const Regex = @import("regex").Regex;

const mem = std.mem;
const Allocator = mem.Allocator;

const megabyte = 1024 * 1024;

const tc_filename_pattern = "report_([a-zA-Z0-9]+-\\d+)_([A-Z]+)_.*";
const master_filename_pattern = "^master_.*?\\.xml$";
const PassedXML    = "passed.xml";
const FailedXML    = "failed.xml";
const RemainingXML = "remaining.xml";
const LogFile = "log.txt";

const Errors = error{
    MasterNotFound,
    MissingXmlProtocolTag,
    FileTooBig,
};

// TODO: 3. Check for memory leaks using valgrind or sth like that
pub fn main() !void {
    std.debug.print("\n", .{});
    var clock1 = try std.time.Timer.start();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    // I think this is not needed when using ArenaAllocator
    // defer std.debug.assert(gpa.deinit() == .ok);

    var dir = std.fs.cwd();

    dir.deleteFile(LogFile) catch {};
    dir.deleteFile(PassedXML) catch {};
    dir.deleteFile(FailedXML) catch {};
    dir.deleteFile(RemainingXML) catch {};

    const master_xml = try getMasterFile(alloc, &dir);
    log("Found master: {s}\n", .{master_xml});
    var xml_text = try readFile(&dir, master_xml);

    const xml_document = try xml.parse(alloc, xml_text);
    defer xml_document.deinit();

    var protocolsMap = try getProtocolsFromXml(alloc, xml_document.root);
    defer protocolsMap.deinit();

    var result = try getTestsFromDir(alloc, &dir);
    log("Found Passed TCs: {s}", .{result.passed});
    log("Found Failed TCs: {s}", .{result.failed});

    var passedProtocols = try getProtocolsFromIds(alloc, &protocolsMap, result.passed);
    var failedProtocols = try getProtocolsFromIds(alloc, &protocolsMap, result.failed);

    var remainingProtocols = try getRemainingProtocols(alloc, &protocolsMap, passedProtocols, failedProtocols);
    log("Master: {d}\n", .{protocolsMap.count()});
    log("Passed: {d}\n", .{passedProtocols.len});
    log("Failed: {d}\n", .{failedProtocols.len});
    log("Remaining: {d}\n", .{remainingProtocols.len});

    var out = try makePolarionXmlText(alloc, xml_text, passedProtocols);
    try createOutputFile(&dir, PassedXML, out);

    out = try makePolarionXmlText(alloc, xml_text, failedProtocols);
    try createOutputFile(&dir, FailedXML, out);

    out = try makePolarionXmlText(alloc, xml_text, remainingProtocols);
    try createOutputFile(&dir, RemainingXML, out);

    log("Generated xml files\n", .{});
    const zig_time = clock1.read();
    std.debug.print("Time: {any}\n", .{std.fmt.fmtDuration(zig_time)});
}

pub fn log(
    comptime format: []const u8,
    args: anytype,
) void {
    const logfile = std.fs.cwd().createFile(LogFile, .{ .truncate = false }) catch return;
    defer logfile.close();
    const writer = logfile.writer();
    const end = logfile.getEndPos() catch return;
    logfile.seekTo(end) catch return;

    const timestamp = std.time.timestamp();

    writer.print("{}: " ++ format, .{ timestamp } ++ args) catch return;
    std.debug.print("{}: " ++ format, .{ timestamp } ++ args);
}

// NOTE: This and getTestsFromDir loops over current directory twice which is unnecessary
fn getMasterFile(alloc: Allocator, dir: *std.fs.Dir) ![]const u8 {
    var master_filename_re = try Regex.compile(alloc, master_filename_pattern);
    defer master_filename_re.deinit();
    
    var dir_iter = try dir.openIterableDir(".", .{});
    defer dir_iter.close();

    var walker = try dir_iter.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (try master_filename_re.match(entry.basename)) {
            return alloc.dupe(u8, entry.path);
        }
    }

    return error.MasterNotFound;
}

fn createOutputFile(dir: *std.fs.Dir, filename: []const u8, data: []const u8) !void {
    const file = try dir.createFile( filename, .{ .read = true },);
    defer file.close();

    try file.writeAll(data);
}

pub fn readFile(dir: *std.fs.Dir, filename: []const u8) ![]const u8 {
    var file = try dir.openFile(filename, .{});
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

/// Get a map with TC ids as keys and pointer to xml element as values.
/// The caller owns the data and is responsible for `.deinit()`
pub fn getProtocolsFromXml(alloc: Allocator, root: *xml.Element) !std.StringHashMap(*xml.Element) {
    var list = std.ArrayList(*xml.Element).init(alloc);
    defer list.deinit();

    try root.allElements(&list, "protocol");

    // TODO: maybe the map should contain a pointer to custom elem that holds all data?
    var passedMap = std.StringHashMap(*xml.Element).init(alloc);
    for (list.items) |protocol| {
        if (protocol.getAttribute("id")) |tc_id| {
            try passedMap.put(tc_id, protocol);
        }
    }

    return passedMap;
}

pub const GetTestsFromDirResult = struct {
    passed: []const []const u8,
    failed: []const []const u8,
};

// TODO: Path parameter should be the CWD
pub fn getTestsFromDir(alloc: Allocator, dir: *std.fs.Dir) !GetTestsFromDirResult {
    var tc_filename_re = try Regex.compile(alloc, tc_filename_pattern);
    defer tc_filename_re.deinit();

    var passedMap = std.StringHashMap(u8).init(alloc);
    defer passedMap.deinit();

    var failedMap = std.StringHashMap(u8).init(alloc);
    defer failedMap.deinit();

    var failedDuplicates = std.ArrayList([]const u8).init(alloc);
    defer failedDuplicates.deinit();

    var dir_iter = try dir.openIterableDir(".", .{});
    defer dir_iter.close();

    var walker = try dir_iter.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const res = try getInfoFromFilename(&tc_filename_re, entry.basename);
        if (res == null) {
            continue;
        }
        const result = res.?;
        const tc_id = try alloc.dupe(u8, result.tc_id);

        if (std.mem.eql(u8, result.status, "PASS")) {
            if (passedMap.get(tc_id) == null) {
                try passedMap.put(tc_id, 0);
            }
        } else {
            if (failedMap.get(tc_id)) |_| {
                try failedDuplicates.append(tc_id);
            } else {
                try failedMap.put(tc_id, 0);
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

    log("Failed TCs that later passed: {s}\n", .{try failedThatPassed.toOwnedSlice()});
    log("Failed Multiple Times: {s}\n", .{try failedDuplicates.toOwnedSlice()});

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

/// Caller owns the returned data
fn getProtocolsFromIds(
    alloc: Allocator,
    protocolsMap: *std.StringHashMap(*xml.Element),
    tcIds: []const []const u8
) ![]*xml.Element {
    var list = std.ArrayList(*xml.Element).init(alloc);
    defer list.deinit();

    for (tcIds) |tcId| {
        if (protocolsMap.get(tcId)) |xml_elem| {
            try list.append(xml_elem);
        }
    }
    return list.toOwnedSlice();
}

/// Caller owns the returned data
fn getRemainingProtocols(
    alloc: Allocator,
    protocolsMap: *std.StringHashMap(*xml.Element),
    passed: []*xml.Element,
    failed: []*xml.Element
) ![]*xml.Element {
    var remaining = std.ArrayList(*xml.Element).init(alloc);
    defer remaining.deinit();

    var seenMap = std.StringHashMap(u8).init(alloc);
    defer seenMap.deinit();

    var protocolsKeyIter = protocolsMap.keyIterator();
    while (protocolsKeyIter.next()) |tc_id| {
        var result = try seenMap.getOrPut(tc_id.*);
        if (result.found_existing) {
            result.value_ptr.* += 1;
        } else {
            result.value_ptr.* = 0;
        }
    }

    // TODO: this is inefficient - i already had a map of tc_id -> *xml.Element for passed and failed elems
    // There is no need to convert it to a slice of *xml.Element and here search for the ID attribute of each xml.Element
    // Keep it like this for now for fair 1:1 comparison between the Go version and Zig
    for (passed) |xml_elem| {
        if (xml_elem.getAttribute("id")) |tc_id| {
            var result = try seenMap.getOrPut(tc_id);
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 0;
            }
        }
    }

    for (failed) |xml_elem| {
        if (xml_elem.getAttribute("id")) |tc_id| {
            var result = try seenMap.getOrPut(tc_id);
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 0;
            }
        }
    }

    var seenIter = seenMap.iterator();
    while (seenIter.next()) |entry| {
        if (entry.value_ptr.* != 0) {
            continue;
        }

        if (protocolsMap.get(entry.key_ptr.*)) |xml_elem| {
            try remaining.append(xml_elem);
        }
    }
    return remaining.toOwnedSlice();
}

fn makePolarionXmlText(
    alloc: Allocator,
    master_xml_txt: []const u8,
    protocols: []*xml.Element
) ![]const u8 {
    const start_str = "<protocols>";
    const end_str = "</protocols>";

    const protocols_start_idx = std.mem.indexOf(u8, master_xml_txt, start_str);
    const protocols_end_idx = std.mem.indexOf(u8, master_xml_txt, end_str);
    if ((protocols_start_idx == null) or (protocols_end_idx == null)) {
        return error.MissingXmlProtocolTag;
    }
    const start_idx = protocols_start_idx.? + start_str.len;
    const end_idx = protocols_end_idx.?;

    var out_txt = master_xml_txt[0..start_idx];
    for (protocols) |protocol| {
        const protocol_txt = try makeProtocolTxt(alloc, protocol);
        out_txt = try std.fmt.allocPrint(alloc, "\n{s}\n{s}", .{ out_txt, protocol_txt });
    }

    out_txt = try std.fmt.allocPrint(
        alloc,
        "\n{s}\n{s}",
        .{ out_txt, master_xml_txt[end_idx .. master_xml_txt.len - 1] }
    );

    return out_txt;
}

fn makeProtocolTxt(alloc: Allocator, xml_elem: *xml.Element) ![]const u8 {
    const project_id = xml_elem.getAttribute("project-id").?;
    const tc_id = xml_elem.getAttribute("id").?;
    const test_script_reference = xml_elem.getCharData("test-script-reference").?;

    const protocol_template =
        \\<protocol project-id="{s}" id="{s}">
        \\    <test-script-reference>{s}</test-script-reference>
        \\</protocol>
    ;
    return try std.fmt.allocPrint(
        alloc,
        protocol_template,
        .{ project_id, tc_id, test_script_reference }
    );
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
    //     print("{d} {} {s}\n", .{ idx, @TypeOf(elem), elem.tag });

    //     if (elem.getAttribute("id")) |id| {
    //         print("{s}\n", .{id});
    //     }
    // }
}

test "regex simple pattern match" {
    // const filename_pattern = "report_(?P<id>[a-zA-Z0-9]+-\\d+)_(?P<status>[A-Z]+)_.*";
    var re = try Regex.compile(std.testing.allocator, tc_filename_pattern);
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
