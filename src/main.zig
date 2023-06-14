const std = @import("std");
const xml = @import("xml.zig");


const mem = std.mem;
const Allocator = mem.Allocator;

const master_xml = "src/master_cleaning.xml";
const megabyte = 1024 * 1024;

pub fn main() !void {
    var xml_text = try readFile(master_xml);

    var alloc = std.heap.page_allocator;
    const xml_document = try xml.parse(alloc, xml_text);
    defer xml_document.deinit();

    var list = try getProtocolsFromXml(alloc, xml_document.root);
    std.debug.print("list len: {d}\n", .{list.len});

    for (list, 0..) |elem, idx| {
        std.debug.print("{d} {} {s}\n", .{idx, @TypeOf(elem), elem.tag});

        // if (elem.getAttribute("id")) |id| {
        //     std.debug.print("{s}\n", .{id});
        // }
    }
}

const ReadFileError = error {
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
    var list = std.ArrayList(xml.Element).init(alloc);
    defer list.deinit();

    try root.allElements(&list, "protocol");

    return list.toOwnedSlice();
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

    for (list.items, 0..) |elem, idx| {
        std.debug.print("{d} {} {s}\n", .{idx, @TypeOf(elem), elem.tag});

        if (elem.getAttribute("id")) |id| {
            std.debug.print("{s}\n", .{id});
        }
    }

    try std.testing.expect(root.children.len == 1);
}
