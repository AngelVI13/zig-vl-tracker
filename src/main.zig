const std = @import("std");
const xml = @import("xml.zig");

const master_xml = "src/master_cleaning.xml";
const megabyte = 1024 * 1024;

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    var file = try std.fs.cwd().openFile(master_xml, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    var buf: [1 * megabyte]u8 = undefined;
    var n = try in_stream.readAll(&buf);

    std.debug.print("Read {d} bytes", .{n});
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
    std.debug.print("{d}\n", .{root.children.len});

    // NOTE: findChildrenByTag is not recursive
    var protocols = root.findChildrenByTag("dv-plan");
    std.debug.print("Begin WHILE\n", .{});
    while (protocols.next()) |protocol| {
        std.debug.print("{s}\n", .{protocol.tag});
    }
    std.debug.print("After WHILE\n", .{});

    try std.testing.expect(root.children.len == 1);
}
