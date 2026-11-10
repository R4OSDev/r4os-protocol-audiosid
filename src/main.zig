const r4os = @import("r4os");

comptime {
    if (!@import("builtin").is_test) asm (r4os.technical2.protocolEntriesAsm("sid_init", "sid_shutdown", "sid_query", "sid_dispatch"));
}

export fn sid_init(api: *const r4os.r4dev.ProtocolApi2) callconv(.c) i32 {
    const ctx = r4os.r4dev.ProtocolContext2.init(api);
    if (!ctx.requires(.{ "register_role", "set_status" })) return r4os.abi.err_no_fn;
    const registered = ctx.registerRole("audio.sid", .audio, 0);
    if (registered != 0) return registered;
    return ctx.setStatus(.active, "SID protocol R4P active");
}

export fn sid_shutdown() callconv(.c) i32 {
    return 0;
}

export fn sid_query(out: *r4os.abi.ProtocolStatus) callconv(.c) i32 {
    out.* = .{
        .state = @intFromEnum(r4os.abi.ProtocolState.active),
        .flags = 0,
        .last_error = 0,
        .reserved = 0,
        .note = note("SID protocol R4P ready"),
    };
    return 0;
}

export fn sid_dispatch(op: u32, in_buffer: *const r4os.abi.ProtocolBuffer, out_buffer: *r4os.abi.ProtocolBuffer) callconv(.c) i32 {
    _ = out_buffer;
    const request = requestFromBuffer(in_buffer) orelse return r4os.abi.audio_sid_result_unsupported;
    switch (op) {
        r4os.abi.audio_sid_op_configure_model => configureModel(request),
        r4os.abi.audio_sid_op_write_register => classifyRegister(request),
        r4os.abi.audio_sid_op_resolve_io => resolveIo(request),
        r4os.abi.audio_sid_op_self_test => selfTest(request),
        else => return r4os.abi.audio_sid_result_unsupported,
    }
    return request.result;
}

fn configureModel(op: *r4os.abi.AudioSidOp) void {
    if (op.model != r4os.abi.audio_sid_model_8580 and op.model != r4os.abi.audio_sid_model_6581) {
        op.result = r4os.abi.audio_sid_result_bad_model;
        return;
    }
    op.result = r4os.abi.audio_sid_result_ok;
}

fn classifyRegister(op: *r4os.abi.AudioSidOp) void {
    if (op.register >= 0x19) {
        op.result = r4os.abi.audio_sid_result_bad_register;
        return;
    }
    op.kind = registerKind(op.register);
    op.voice = if (op.kind == r4os.abi.audio_sid_register_voice) op.register / 7 else 0;
    op.result = r4os.abi.audio_sid_result_ok;
}

fn resolveIo(op: *r4os.abi.AudioSidOp) void {
    if (op.address < 0xD400 or op.address > 0xD7FF) {
        op.result = r4os.abi.audio_sid_result_bad_address;
        return;
    }
    op.register = @intCast((op.address - 0xD400) & 0x001F);
    op.mirrored = 1;
    if (op.register >= 0x19) {
        op.kind = r4os.abi.audio_sid_register_readback;
    } else {
        classifyRegister(op);
        return;
    }
    op.result = r4os.abi.audio_sid_result_ok;
}

fn selfTest(op: *r4os.abi.AudioSidOp) void {
    var probe = r4os.abi.AudioSidOp{ .model = r4os.abi.audio_sid_model_8580 };
    configureModel(&probe);
    if (probe.result != r4os.abi.audio_sid_result_ok) {
        op.result = probe.result;
        return;
    }
    probe = .{ .register = 0x04, .value = 0x11 };
    classifyRegister(&probe);
    if (probe.result != r4os.abi.audio_sid_result_ok or probe.kind != r4os.abi.audio_sid_register_voice or probe.voice != 0) {
        op.result = r4os.abi.audio_sid_result_bad_register;
        return;
    }
    probe = .{ .register = 0x17, .value = 0xF0 };
    classifyRegister(&probe);
    if (probe.kind != r4os.abi.audio_sid_register_filter) {
        op.result = r4os.abi.audio_sid_result_bad_register;
        return;
    }
    probe = .{ .address = 0xD41B };
    resolveIo(&probe);
    if (probe.result != r4os.abi.audio_sid_result_ok or probe.register != 0x1B or probe.kind != r4os.abi.audio_sid_register_readback) {
        op.result = r4os.abi.audio_sid_result_bad_address;
        return;
    }
    op.result = r4os.abi.audio_sid_result_ok;
}

fn registerKind(reg: u8) u8 {
    if (reg <= 0x14) return r4os.abi.audio_sid_register_voice;
    if (reg == 0x15 or reg == 0x16 or reg == 0x17) return r4os.abi.audio_sid_register_filter;
    if (reg == 0x18) return r4os.abi.audio_sid_register_volume;
    return r4os.abi.audio_sid_register_other;
}

fn requestFromBuffer(buffer: *const r4os.abi.ProtocolBuffer) ?*r4os.abi.AudioSidOp {
    const native = r4os.native_protocol_view;
    // These are caller-owned native classifier records, not timed PCM/device
    // submissions. Their exclusive dispatch loan ends at this return.
    var metadata = buffer.*;
    return (native.InOut(r4os.abi.AudioSidOp).init(&metadata, native.Policy.record(r4os.abi.AudioSidOp, .inout, .prefix)) catch return null).value;
}

fn note(comptime text: []const u8) [64]u8 {
    var out: [64]u8 = .{0} ** 64;
    @memcpy(out[0..text.len], text);
    return out;
}
