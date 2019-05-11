const std = @import("std");

fn fft_bit_reverse(N: usize, re: []f32, im: []f32) void {
    var h: usize = undefined;
    var j: usize = 0;
    var k: usize = undefined;
    var i_2 = N >> 1;

    var tmp: f32 = undefined;

    h = 0; while (h < N - 2) : (h += 1) {
        if (h < j) {
            tmp = re[h]; re[h] = re[j]; re[j] = tmp;
            tmp = im[h]; im[h] = im[j]; im[j] = tmp;
        }
        k = i_2; while (k <= j) : (k >>= 1) {
            j -= k;
        }
        j += k;
    }
}

pub fn fft(N: usize, re: []f32, im: []f32) void {
    var h: usize = undefined;
    var i_1: usize = undefined;
    var j: usize = 0;
    var k: usize = undefined;
    // var i_2 = N >> 1;
    var l1: usize = undefined;
    var l2: usize = 1;
    var c: f32 = -1.0;
    var s: f32 = 0.0;
    var t1: f32 = undefined;
    var t2: f32 = undefined;
    var u_1: f32 = undefined;
    var u_2: f32 = undefined;

    fft_bit_reverse(N, re, im);

    k = 1; while (k < N) : (k <<= 1) {
        l1 = l2;
        l2 <<= 1;
        u_1 = 1;
        u_2 = 0;
        j = 0; while (j < l1) : (j += 1) {
            h = j; while (h < N) : (h += l2) {
                i_1 = h + l1;
                t2 = (re[i_1] - im[i_1]) * u_2;
                t1 = t2 + re[i_1] * (u_1 - u_2);
                t2 = t2 + im[i_1] * (u_1 + u_2);
                re[i_1] = re[h] - t1;
                im[i_1] = im[h] - t2;
                re[h] += t1;
                im[h] += t2;
            }
            t1 = u_1 * c - u_2 * s;
            u_2 = u_1 * s + u_2 * c;
            u_1 = t1;
        }
        s = -std.math.sqrt((1 - c) * 0.5);
        c =  std.math.sqrt((1 + c) * 0.5);
    }
}
