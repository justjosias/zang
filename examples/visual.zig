const std = @import("std");
const fft = @import("common/fft.zig").fft;
const example = @import(@import("build_options").example);
const Recorder = @import("recorder.zig").Recorder;

const fontdata = @embedFile("font.dat");

pub const fontchar_w = 8;
pub const fontchar_h = 13;

pub fn drawFill(pixels: []u32, pitch: usize, x: usize, y: usize, w: usize, h: usize, color: u32) void {
    var i: usize = 0;
    while (i < h) : (i += 1) {
        const start = (y + i) * pitch + x;
        std.mem.set(u32, pixels[start .. start + w], 0);
    }
}

pub fn drawString(pixels: []u32, pitch: usize, start_x: usize, start_y: usize, s: []const u8) void {
    const color: u32 = 0xAAAAAAAA;

    // warning: does no checking for drawing off screen
    var x = start_x;
    var y = start_y;
    for (s) |ch| {
        if (ch == '\n') {
            x = start_x;
            y += fontchar_h + 1;
        } else if (ch >= 32) {
            const index = @intCast(usize, ch - 32) * fontchar_h;
            var sy: usize = 0;
            while (sy < fontchar_h) : (sy += 1) {
                var sx: usize = 0;
                while (sx < fontchar_w) : (sx += 1) {
                    if ((fontdata[index + sy] & (@as(u8, 1) << @intCast(u3, sx))) != 0) {
                        pixels[(y + sy) * pitch + x + sx] = color;
                    }
                }
            }
            x += fontchar_w + 1;
        }
    }
}

fn hueToRgb(p: f32, q: f32, t_: f32) f32 {
    var t = t_;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

fn hslToRgb(h: f32, s: f32, l: f32) u32 {
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;

    if (s == 0.0) {
        r = 1.0;
        g = 1.0;
        b = 1.0;
    } else {
        const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
        const p = 2 * l - q;
        r = hueToRgb(p, q, h + 1.0 / 3.0);
        g = hueToRgb(p, q, h);
        b = hueToRgb(p, q, h - 1.0 / 3.0);
    }

    // kludge
    const sqrt_h = std.math.sqrt(h);
    r *= sqrt_h;
    g *= sqrt_h;
    b *= sqrt_h;

    return @as(u32, 0xFF000000) |
        (@floatToInt(u32, b * 255) << 16) |
        (@floatToInt(u32, g * 255) << 8) |
        (@floatToInt(u32, r * 255));
}

fn scrollBlit(pixels: []u32, pitch: usize, x: usize, y: usize, w: usize, h: usize, buffer: []const u32, drawindex: usize) void {
    var i: usize = 0;
    while (i < h) : (i += 1) {
        const dest_start = (y + i) * pitch + x;
        const dest = pixels[dest_start .. dest_start + w];

        const src_start = i * w;
        const src = buffer[src_start .. src_start + w];

        std.mem.copy(u32, dest[w - drawindex ..], src[0..drawindex]);
        std.mem.copy(u32, dest[0 .. w - drawindex], src[drawindex..]);
    }
}

fn getFFTValue(f_: f32, in_fft: []const f32, logarithmic: bool) f32 {
    var f = f_;

    if (logarithmic) {
        const exp = 10.0;
        f = (std.math.pow(f32, exp, f) - 1.0) / (exp - 1.0);
    }

    f *= 511.5;
    const f_floor = std.math.floor(f);
    const index0 = @floatToInt(usize, f_floor);
    const index1 = std.math.min(511, index0 + 1);
    const frac = f - f_floor;

    const fft_value0 = in_fft[index0];
    const fft_value1 = in_fft[index1];

    return fft_value0 * (1.0 - frac) + fft_value1 * frac;
}

pub const BlitContext = struct {
    recorder_state: @TagType(Recorder.State),
};

pub const VTable = struct {
    offset: usize, // offset of `vtable: *const VTable` in instance object
    delFn: fn (self: **const VTable, allocator: *std.mem.Allocator) void,
    plotFn: fn (self: **const VTable, samples: []const f32, mul: f32, logarithmic: bool) bool,
    blitFn: fn (self: **const VTable, pixels: []u32, pitch: usize, ctx: BlitContext) void,
};

fn makeVTable(comptime T: type) VTable {
    const S = struct {
        const vtable = VTable{
            .offset = blk: {
                inline for (@typeInfo(T).Struct.fields) |field| {
                    if (comptime std.mem.eql(u8, field.name, "vtable")) {
                        break :blk field.offset.?;
                    }
                }
                @compileError("missing vtable field");
            },
            .delFn = delFn,
            .plotFn = plotFn,
            .blitFn = blitFn,
        };
        fn delFn(self: **const VTable, allocator: *std.mem.Allocator) void {
            @intToPtr(*T, @ptrToInt(self) - self.*.offset).del(allocator);
        }
        fn plotFn(self: **const VTable, samples: []const f32, mul: f32, logarithmic: bool) bool {
            if (!@hasDecl(T, "plot")) return false;
            return @intToPtr(*T, @ptrToInt(self) - self.*.offset).plot(samples, mul, logarithmic);
        }
        fn blitFn(self: **const VTable, pixels: []u32, pitch: usize, ctx: BlitContext) void {
            @intToPtr(*T, @ptrToInt(self) - self.*.offset).blit(pixels, pitch, ctx);
        }
    };
    return S.vtable;
}

// area chart where x=frequency and y=amplitude
pub const DrawSpectrum = struct {
    const _vtable = makeVTable(@This());

    vtable: *const VTable,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    old_y: []u32,
    fft_real: []f32,
    fft_imag: []f32,
    fft_out: []f32,
    logarithmic: bool,
    state: enum { up_to_date, needs_blit, needs_full_reblit },

    pub fn new(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize) !*DrawSpectrum {
        var self = try allocator.create(DrawSpectrum);
        errdefer allocator.destroy(self);
        var old_y = try allocator.alloc(u32, width);
        errdefer allocator.free(old_y);
        var fft_real = try allocator.alloc(f32, 1024);
        errdefer allocator.free(fft_real);
        var fft_imag = try allocator.alloc(f32, 1024);
        errdefer allocator.free(fft_imag);
        var fft_out = try allocator.alloc(f32, 512);
        errdefer allocator.free(fft_out);
        self.* = .{
            .vtable = &_vtable,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .old_y = old_y,
            .fft_real = fft_real,
            .fft_imag = fft_imag,
            .fft_out = fft_out,
            .logarithmic = false,
            .state = .needs_full_reblit,
        };
        // old_y doesn't need to be initialized as long as state is .needs_full_reblit
        std.mem.set(f32, self.fft_out, 0.0);
        return self;
    }

    pub fn del(self: *DrawSpectrum, allocator: *std.mem.Allocator) void {
        allocator.free(self.old_y);
        allocator.free(self.fft_real);
        allocator.free(self.fft_imag);
        allocator.free(self.fft_out);
        allocator.destroy(self);
    }

    pub fn plot(self: *DrawSpectrum, samples: []const f32, _mul: f32, logarithmic: bool) bool {
        std.debug.assert(samples.len == 1024); // FIXME

        std.mem.copy(f32, self.fft_real, samples);
        std.mem.set(f32, self.fft_imag, 0.0);
        fft(1024, self.fft_real, self.fft_imag);

        var i: usize = 0;
        while (i < 512) : (i += 1) {
            const v = std.math.fabs(self.fft_real[i]) * (1.0 / 1024.0);
            const v2 = std.math.sqrt(v); // kludge for visibility
            self.fft_out[i] = v2;
        }

        self.logarithmic = logarithmic;
        if (self.state == .up_to_date) {
            self.state = .needs_blit;
        }

        return true;
    }

    pub fn blit(self: *DrawSpectrum, pixels: []u32, pitch: usize, _context: BlitContext) void {
        if (self.state == .up_to_date) return;
        defer self.state = .up_to_date;

        const background_color: u32 = 0x00000000;
        const color: u32 = 0xFF444444;

        var i: usize = 0;
        while (i < self.width) : (i += 1) {
            const fi = @intToFloat(f32, i) / @intToFloat(f32, self.width - 1);
            const fv = getFFTValue(fi, self.fft_out, self.logarithmic) * @intToFloat(f32, self.height);

            const value = @floatToInt(u32, std.math.floor(fv));
            const value_clipped = std.math.min(value, self.height - 1);

            // new_y is where the graph will transition from background to foreground color
            const new_y = @intCast(u32, self.height - value_clipped);

            // the transition pixel will have a blended color value
            const frac = fv - std.math.floor(fv);
            const co: u32 = @floatToInt(u32, 0x44 * frac);
            const transition_color = @as(u32, 0xFF000000) | (co << 16) | (co << 8) | co;

            const sx = self.x + i;
            var sy = self.y;
            if (self.state == .needs_full_reblit) {
                // redraw fully
                while (sy < self.y + new_y) : (sy += 1) {
                    pixels[sy * pitch + sx] = background_color;
                }
                if (sy < self.y + self.height) {
                    pixels[sy * pitch + sx] = transition_color;
                    sy += 1;
                }
                while (sy < self.y + self.height) : (sy += 1) {
                    pixels[sy * pitch + sx] = color;
                }
            } else {
                const old_y = self.old_y[i];
                if (old_y < new_y) {
                    // new_y is lower down. fill in the overlap with background color
                    sy += old_y;
                    while (sy < self.y + new_y) : (sy += 1) {
                        pixels[sy * pitch + sx] = background_color;
                    }
                    if (sy < self.y + self.height) {
                        pixels[sy * pitch + sx] = transition_color;
                        sy += 1;
                    }
                } else if (old_y > new_y) {
                    // new_y is higher up. fill in the overlap with foreground color
                    sy += new_y;
                    if (sy < self.y + self.height) {
                        pixels[sy * pitch + sx] = transition_color;
                        sy += 1;
                    }
                    // add one to cover up the old transition pixel
                    const until = std.math.min(old_y + 1, self.height);
                    while (sy < self.y + until) : (sy += 1) {
                        pixels[sy * pitch + sx] = color;
                    }
                }
            }

            self.old_y[i] = new_y;
        }
    }
};

// scrolling 2d color plot of FFT data
pub const DrawSpectrumFull = struct {
    const _vtable = makeVTable(@This());

    vtable: *const VTable,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    fft_real: []f32,
    fft_imag: []f32,
    buffer: []u32,
    logarithmic: bool,
    drawindex: usize,

    pub fn new(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize) !*DrawSpectrumFull {
        var self = try allocator.create(DrawSpectrumFull);
        errdefer allocator.destroy(self);
        var fft_real = try allocator.alloc(f32, 1024);
        errdefer allocator.free(fft_real);
        var fft_imag = try allocator.alloc(f32, 1024);
        errdefer allocator.free(fft_imag);
        var buffer = try allocator.alloc(u32, width * height);
        errdefer allocator.free(buffer);
        self.* = .{
            .vtable = &_vtable,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .fft_real = fft_real,
            .fft_imag = fft_imag,
            .buffer = buffer,
            .logarithmic = false,
            .drawindex = 0,
        };
        std.mem.set(u32, self.buffer, 0);
        return self;
    }

    pub fn del(self: *DrawSpectrumFull, allocator: *std.mem.Allocator) void {
        allocator.free(self.fft_real);
        allocator.free(self.fft_imag);
        allocator.free(self.buffer);
        allocator.destroy(self);
    }

    pub fn plot(self: *DrawSpectrumFull, samples: []const f32, _mul: f32, logarithmic: bool) bool {
        if (self.logarithmic != logarithmic) {
            self.logarithmic = logarithmic;
            std.mem.set(u32, self.buffer, 0.0);
            self.drawindex = 0;
        }

        std.debug.assert(samples.len == 1024); // FIXME

        std.mem.copy(f32, self.fft_real, samples);
        std.mem.set(f32, self.fft_imag, 0.0);
        fft(1024, self.fft_real, self.fft_imag);

        var i: usize = 0;
        while (i < self.height) : (i += 1) {
            const f = @intToFloat(f32, i) / @intToFloat(f32, self.height - 1);
            const fft_value = getFFTValue(f, self.fft_real, logarithmic);

            // sqrt is a kludge to make things more visible
            const v = std.math.sqrt(std.math.fabs(fft_value) * (1.0 / 1024.0));

            self.buffer[(self.height - 1 - i) * self.width + self.drawindex] = hslToRgb(v, 1.0, 0.5);
        }

        self.drawindex += 1;
        if (self.drawindex == self.width) {
            self.drawindex = 0;
        }

        return true;
    }

    pub fn blit(self: *DrawSpectrumFull, pixels: []u32, pitch: usize, _ctx: BlitContext) void {
        scrollBlit(pixels, pitch, self.x, self.y, self.width, self.height, self.buffer, self.drawindex);
    }
};

// scrolling waveform view
pub const DrawWaveform = struct {
    const _vtable = makeVTable(@This());

    vtable: *const VTable,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    buffer: []u32,
    drawindex: usize,
    dirty: bool,

    const background_color: u32 = 0x18181818;
    const waveform_color: u32 = 0x44444444;
    const clipped_color: u32 = 0xFFFF0000;
    const center_line_color: u32 = 0x66666666;

    pub fn new(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize) !*DrawWaveform {
        var self = try allocator.create(DrawWaveform);
        errdefer allocator.destroy(self);
        var buffer = try allocator.alloc(u32, width * height);
        errdefer allocator.free(buffer);
        self.* = .{
            .vtable = &_vtable,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .buffer = buffer,
            .drawindex = 0,
            .dirty = true,
        };
        std.mem.set(u32, self.buffer, background_color);
        const start = height / 2 * width;
        std.mem.set(u32, self.buffer[start .. start + width], center_line_color);
        return self;
    }

    pub fn del(self: *DrawWaveform, allocator: *std.mem.Allocator) void {
        allocator.free(self.buffer);
        allocator.destroy(self);
    }

    pub fn plot(self: *DrawWaveform, samples: []const f32, mul: f32, _logarithmic: bool) bool {
        var sample_min = samples[0];
        var sample_max = samples[0];
        for (samples[1..]) |sample| {
            if (sample < sample_min) sample_min = sample;
            if (sample > sample_max) sample_max = sample;
        }
        sample_min *= mul;
        sample_max *= mul;

        const y_mid = self.height / 2;
        const sample_min_clipped = std.math.max(-1.0, sample_min);
        const sample_max_clipped = std.math.min(1.0, sample_max);
        var y0 = @floatToInt(usize, @intToFloat(f32, y_mid) - sample_max * @intToFloat(f32, self.height / 2) + 0.5);
        var y1 = @floatToInt(usize, @intToFloat(f32, y_mid) - sample_min * @intToFloat(f32, self.height / 2) + 0.5);
        var sx = self.drawindex;
        var sy: usize = 0;
        var until: usize = undefined;

        if (sample_max >= 1.0) {
            self.buffer[sy * self.width + sx] = clipped_color;
            sy += 1;
        }
        until = std.math.min(y0, y_mid);
        while (sy < until) : (sy += 1) {
            self.buffer[sy * self.width + sx] = background_color;
        }
        until = std.math.min(y1, y_mid);
        while (sy < until) : (sy += 1) {
            self.buffer[sy * self.width + sx] = waveform_color;
        }
        while (sy < y_mid) : (sy += 1) {
            self.buffer[sy * self.width + sx] = background_color;
        }
        self.buffer[sy * self.width + sx] = center_line_color;
        sy += 1;
        if (y0 > y_mid) {
            until = std.math.min(y0, self.height);
            while (sy < until) : (sy += 1) {
                self.buffer[sy * self.width + sx] = background_color;
            }
        }
        until = std.math.min(y1, self.height);
        while (sy < until) : (sy += 1) {
            self.buffer[sy * self.width + sx] = waveform_color;
        }
        while (sy < self.height) : (sy += 1) {
            self.buffer[sy * self.width + sx] = background_color;
        }
        if (sample_min <= -1.0) {
            sy -= 1;
            self.buffer[sy * self.width + sx] = background_color;
        }

        self.dirty = true;
        self.drawindex += 1;
        if (self.drawindex == self.width) {
            self.drawindex = 0;
        }

        return true;
    }

    pub fn blit(self: *DrawWaveform, pixels: []u32, pitch: usize, _ctx: BlitContext) void {
        if (!self.dirty) return;
        self.dirty = false;

        scrollBlit(pixels, pitch, self.x, self.y, self.width, self.height, self.buffer, self.drawindex);
    }
};

pub const DrawStaticString = struct {
    const _vtable = makeVTable(@This());

    vtable: *const VTable,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    drawn: bool,
    string: []const u8,

    pub fn new(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize, string: []const u8) !*DrawStaticString {
        var self = try allocator.create(DrawStaticString);
        errdefer allocator.destroy(self);
        self.* = .{
            .vtable = &_vtable,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .drawn = false,
            .string = string,
        };
        return self;
    }

    pub fn del(self: *DrawStaticString, allocator: *std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn blit(self: *DrawStaticString, pixels: []u32, pitch: usize, ctx: BlitContext) void {
        if (self.drawn) return;
        self.drawn = true;

        drawFill(pixels, pitch, self.x, self.y, self.width, self.height, 0);
        drawString(pixels, pitch, self.x, self.y, self.string);
    }
};

pub const DrawRecorderState = struct {
    const _vtable = makeVTable(@This());

    vtable: *const VTable,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    recorder_state: @TagType(Recorder.State),

    pub fn new(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize) !*DrawRecorderState {
        var self = try allocator.create(DrawRecorderState);
        errdefer allocator.destroy(self);
        self.* = .{
            .vtable = &_vtable,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .recorder_state = .idle,
        };
        return self;
    }

    pub fn del(self: *DrawRecorderState, allocator: *std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn blit(self: *DrawRecorderState, pixels: []u32, pitch: usize, ctx: BlitContext) void {
        if (self.recorder_state == ctx.recorder_state) return;
        self.recorder_state = ctx.recorder_state;

        drawFill(pixels, pitch, self.x, self.y, self.width, self.height, 0);
        drawString(pixels, pitch, self.x, self.y, switch (ctx.recorder_state) {
            .idle => "",
            .recording => "RECORDING",
            .playing => "PLAYING BACK",
        });
    }
};

pub const Visuals = struct {
    const State = enum {
        disabled,
        main,
        full_fft,
    };

    allocator: *std.mem.Allocator,
    screen_w: usize,
    screen_h: usize,

    state: State,
    clear: bool,
    widgets: std.ArrayList(**const VTable),

    logarithmic_fft: bool,

    pub fn init(allocator: *std.mem.Allocator, screen_w: usize, screen_h: usize) !Visuals {
        var self: Visuals = .{
            .allocator = allocator,
            .screen_w = screen_w,
            .screen_h = screen_h,
            .state = .main,
            .clear = true,
            .widgets = std.ArrayList(**const VTable).init(allocator),
            .logarithmic_fft = false,
        };
        self.setState(.main);
        return self;
    }

    pub fn deinit(self: *Visuals) void {
        self.clearWidgets();
        self.widgets.deinit();
    }

    fn clearWidgets(self: *Visuals) void {
        while (self.widgets.popOrNull()) |widget| {
            widget.*.delFn(widget, self.allocator);
        }
    }

    fn addWidget(self: *Visuals, inew: var) !void {
        var instance = try inew;
        self.widgets.append(&instance.vtable) catch |err| {
            instance.del(self.allocator);
            return err;
        };
    }

    fn addWidgets(self: *Visuals) !void {
        const fft_height = 128;
        const waveform_height = 81;
        const bottom_padding = fontchar_h;

        switch (self.state) {
            .disabled,
            .main,
            => {
                try self.addWidget(DrawStaticString.new(
                    self.allocator,
                    12,
                    13,
                    self.screen_w - 12,
                    self.screen_h - bottom_padding - waveform_height - 13,
                    example.DESCRIPTION,
                ));
                if (self.state == .disabled) {
                    try self.addWidget(DrawStaticString.new(
                        self.allocator,
                        12,
                        440,
                        self.screen_w - 12,
                        fontchar_h,
                        "Press F1 to re-enable drawing",
                    ));
                } else {
                    try self.addWidget(DrawWaveform.new(
                        self.allocator,
                        0,
                        self.screen_h - bottom_padding - waveform_height,
                        self.screen_w,
                        waveform_height,
                    ));
                    try self.addWidget(DrawSpectrum.new(
                        self.allocator,
                        0,
                        self.screen_h - bottom_padding - waveform_height - fft_height,
                        self.screen_w,
                        fft_height,
                    ));
                }
            },
            .full_fft => {
                try self.addWidget(DrawSpectrumFull.new(self.allocator, 0, 0, self.screen_w, self.screen_h - fontchar_h));
            },
        }

        try self.addWidget(DrawRecorderState.new(
            self.allocator,
            0,
            self.screen_h - fontchar_h,
            self.screen_w,
            fontchar_h,
        ));
    }

    pub fn setState(self: *Visuals, state: State) void {
        self.clearWidgets();
        self.state = state;
        self.addWidgets() catch |err| {
            std.debug.warn("error while initializing widgets: {}\n", .{err});
        };
        self.clear = true;
    }

    pub fn toggleDisabled(self: *Visuals) void {
        if (self.state == .disabled) {
            self.setState(.main);
        } else {
            self.setState(.disabled);
        }
    }

    pub fn toggleFullFFTView(self: *Visuals) void {
        if (self.state == .full_fft) {
            self.setState(.main);
        } else {
            self.setState(.full_fft);
        }
    }

    pub fn toggleLogarithmicFFT(self: *Visuals) void {
        self.logarithmic_fft = !self.logarithmic_fft;
    }

    // called on the audio thread.
    // return true if a redraw should be triggered
    pub fn newInput(self: *Visuals, samples: []const f32, mul: f32) bool {
        var redraw = false;

        var j: usize = 0;
        while (j < samples.len / 1024) : (j += 1) {
            const output = samples[j * 1024 .. j * 1024 + 1024];

            for (self.widgets.items) |widget| {
                if (widget.*.plotFn(widget, output, mul, self.logarithmic_fft)) {
                    redraw = true;
                }
            }
        }

        return redraw;
    }

    // called on the main thread with the audio thread locked
    pub fn blit(self: *Visuals, pixels: []u32, pitch: usize, ctx: BlitContext) void {
        if (self.clear) {
            self.clear = false;
            std.mem.set(u32, pixels, 0);
        }

        for (self.widgets.items) |widget| {
            widget.*.blitFn(widget, pixels, pitch, ctx);
        }
    }
};
