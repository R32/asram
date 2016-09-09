package mem.struct;

import mem.Ptr;

/*
 Copyright (c) 2008-2009 Bjoern Hoehrmann <bjoern@hoehrmann.de>
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 The above copyright notice and this permission notice shall be included
 in all copies or substantial portions of the Software.
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 DEALINGS IN THE SOFTWARE.
*/

@:enum private abstract UTF8Valid(Int) to Int {
	var UTF8_ACCEPT = 0;
	var UTF8_REJECT = 1;
}

/**
ported from http://bjoern.hoehrmann.de/utf-8/decoder/dfa/
*/
class Utf8 {

	public var utf8d(default, null): AU8;

	private function new() {
		var data = [
			0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, // 00..1f
			0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, // 20..3f
			0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, // 40..5f
			0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, // 60..7f
			1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9, // 80..9f
			7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7, // a0..bf
			8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2, // c0..df
			0xa,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x4,0x3,0x3, // e0..ef
			0xb,0x6,0x6,0x6,0x5,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8, // f0..ff
			0x0,0x1,0x2,0x3,0x5,0x8,0x7,0x1,0x1,0x1,0x4,0x6,0x1,0x1,0x1,0x1, // s0..s0
			1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1,1,1,0,1,0,1,1,1,1,1,1, // s1..s2
			1,2,1,1,1,1,1,2,1,2,1,1,1,1,1,1,1,1,1,1,1,1,1,2,1,1,1,1,1,1,1,1, // s3..s4
			1,2,1,1,1,1,1,1,1,2,1,1,1,1,1,1,1,1,1,1,1,1,1,3,1,3,1,1,1,1,1,1, // s5..s6
			1,3,1,1,1,1,1,3,1,3,1,1,1,1,1,1,1,3,1,1,1,1,1,1,1,1,1,1,1,1,1,1, // s7..s8
		];
		utf8d = cast Malloc.make(data.length, false);
		for (i in 0...data.length)
			utf8d[i] = data[i];
	}

	function free(): Void {
		Malloc.free(utf8d);
		utf8d = cast Malloc.NUL;
	}

	static var inst:Utf8 = null;
	public static function init() {
		if (inst == null) inst = new Utf8();
	}

	public static function validate(dst:Ptr, byteLength: Int): Bool {
		var utf8d = inst.utf8d;
		var state = 0;
		for (i in 0...byteLength) {
			var byte = Memory.getByte(dst + i);
			var type = utf8d[byte];

			state = utf8d[256 + (state << 4) + type];

			if (state == UTF8_REJECT) return false;
		}
		return state == UTF8_ACCEPT;
	}


	public static function length(dst:Ptr, byteLength: Int):Int {
		var utf8d = inst.utf8d;
		var len = 0, state = 0;

		for (i in 0...byteLength) {
			var byte = Memory.getByte(dst + i);
			var type = utf8d[byte];

			state = utf8d[256 + (state << 4) + type];

			if (state == UTF8_REJECT)
				return -1; //throw "Invalid utf8 string";
			else if (state == UTF8_ACCEPT)
				len += 1;
		}
		return len;
	}

	public static function iter(dst:Ptr, byteLength: Int, chars : Int -> Void ):Bool {
		var utf8d = inst.utf8d;
		var state = 0, codep = 0;
		for (i in 0...byteLength) {
			var byte = Memory.getByte(dst + i);
			var type = utf8d[byte];

			codep = state != UTF8_ACCEPT ?
				(byte & 0x3f) | (codep << 6) :
				(0xff >> type) & (byte);

			state = utf8d[256 + (state << 4) + type];

			if (state == UTF8_REJECT)
				return false;
			else if (state == UTF8_ACCEPT)
				chars(codep);
		}
		return true;
	}
}
