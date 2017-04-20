package mem;

import mem.Ptr;
import mem.Struct;

/**
e.g:
--- Block.CAPACITY: 16 .OFFSET_FIRST: 0, ::baseAddr: 328
offset: 0x00 - 0x02, bytes: 2, zero: 0
offset: 0x02 - 0x03, bytes: 1, is_free: false
offset: 0x03 - 0x04, bytes: 1, unknown: 0
offset: 0x04 - 0x08, bytes: 4, size: 32
offset: 0x08 - 0x0C, bytes: 4, prev: 168
offset: 0x0C - 0x10, bytes: 4, next: 376
*/
#if !macro
@:build(mem.Struct.StructBuild.make())
#end
@:allow(mem.Malloc) @:dce abstract Block(Ptr) to Ptr {
	@idx(2) var zero: Int;      // 2 bytes, always 0
	@idx(0) var is_free: Bool;  // 1 bytes, if true, will be remove from chain
	@idx(1) var unknown: Int;   // 1 bytes
	@idx(4) var size: Int;      // 4 bytes, The whole block
	@idx(0) var prev: Block;    // 4 bytes, Pointer to prev Block, idx(0) is a offset
	@idx(0) var next: Block;    // 4 bytes

	public var entry(get, never):Ptr;
	inline function get_entry():Ptr return this + OFFSET_END;

	public var entrySize(get, never):Int;
	inline function get_entrySize():Int return size - CAPACITY;

	inline private function new(block_addr:Ptr, req_size:Int, clear:Bool) {
		this = block_addr;
		Ram.memset(this, 0, (clear ? req_size + CAPACITY : CAPACITY));
		size = req_size + CAPACITY;	// Note: must after memset
	}

	inline public function free() @:privateAccess Malloc.freeBlock(cast this);
}

@:access(Ram) class Malloc {

	public static inline var NUL:Ptr = cast 0;
	public static inline var LB = 8;

	static var top(default, null):Block = cast NUL;
	static var bottom(default, null):Block = cast NUL;
	public static var frag_count(default, null):Int = 0;
	public static var length(default, null):Int = 0;

	public static function getUsed():Int {
		return bottom == NUL ? 16 : (bottom:Int) + bottom.size; // Reserve 16 bytes
	}

	// e.g: .calcEntrySize( someStruct.realEntry() )
	public static function calcEntrySize(entry: Ptr): Int {
		var b = indexOf(entry);
		if (b != NUL)
			return b.entrySize;
		return 0;
	}

	static function clear() {
		top = cast NUL;
		bottom = cast NUL;
		frag_count = 0;
		length = 0;
	}

	// add element at the end of this chain, Only for New Empty Block
	static function add(b:Block):Void {
		if (top == NUL) {
			top = b;
		} else {
			bottom.next = b;
			b.prev = bottom;
		}
		bottom = b;
		++ length;
	}

	// b after a
	static function insertAfter(b:Block, a:Block):Void {
		var cc = a.next;
		a.next = b;
		b.prev = a;
		b.next = cc;
		if (cc == NUL)
			bottom = b;
		else
			cc.prev = b;
		++ length;
	}

	static function indexOf(entry:Ptr):Block {
		if (entry - Block.CAPACITY > NUL) {
			var b:Block = cast entry - Block.CAPACITY;
			//if (b == bottom || b == top || (b.prev.next == b && b.next.prev == b))
			//	return b;
			if (b == bottom || b == top) return b;
			var prev = b.prev, next = b.next;      // for Too many local variables
			if (prev.next == b && next.prev == b) return b;
		}
		return cast NUL;
	}

	public static function make(req_size:Int, zero:Bool, pb:Int):Ptr {
		if (pb != LB && (((pb & LB - 1) != 0)) || pb < LB) pb = LB;

		req_size = Ut.padmul(req_size, pb);

		//if (frag_count > 0) mergeFragment();

		var tmp_frag_count = frag_count;
		var block:Block = cast NUL;
		var poolEntrySize = 0;
		var cc:Block = top;
		while (tmp_frag_count > 0 && cc != NUL) {
			if (cc.is_free) {
				poolEntrySize = cc.entrySize;
				if (poolEntrySize == req_size) {
					block = cc;
					break;
				} else if (block == NUL && poolEntrySize > req_size) {
					block = cc;
				}
				-- tmp_frag_count;
			}
			cc = cc.next;
		}

		var entrySizeAb = req_size + Block.CAPACITY;

		if(block == NUL) {
			var blockAddr = getUsed();
			Ram.req(blockAddr + entrySizeAb); // check
			block = new Block(cast blockAddr, req_size, zero);
			add(block);
		} else {
			poolEntrySize = block.entrySize;  // N.B: poolEntrySize does not contain its own "Block.CAPACITY"
			if (entrySizeAb >= 64 && poolEntrySize >= (entrySizeAb + req_size)) { // if double size then split
				var nextBlock = new Block((block:Ptr) + entrySizeAb, poolEntrySize - entrySizeAb, false);
				nextBlock.is_free = true;
				insertAfter(nextBlock, block);
				block.size = entrySizeAb;
			} else {
				-- frag_count;
			}
			block.is_free = false;
		}
		return block.entry;
	}

	public static inline function free(p:Ptr) freeBlock(indexOf(p));

	static function freeBlock(b: Block) :Void {
		if (b == NUL || bottom == NUL || b.is_free) return;

		b.is_free = true;

		++ frag_count;

		if (b == bottom) {
			while (bottom.is_free) {
				bottom = bottom.prev;
				-- length;
				-- frag_count;
				if (bottom == NUL)
					top = bottom;
				else
					bottom.next = cast NUL;
			}
		}
	}

	public static function dump(): String {
		return '-- Volume: ${Ram.current.length / 1024}KB, USAGE: ${getUsed() / 1024}KB, Blocks: $length, Fragments: $frag_count, Check: ${check()}';
	}

	static function mergeFragment() {
		var next:Block = cast NUL;
		var head:Block = top;
		while (head != NUL && frag_count > 0) {		// if head == null, Is empty
			if (head.is_free) {
				next = head.next;
				if (next != NUL && next.is_free) {	// if next == null, next is BOTTOM
					head.next = next.next;			// Note: next.next
					if (head.next == NUL) {
						bottom = head;
					} else {
						head.next.prev = head;
					}
					head.size += next.size;
					-- frag_count;
					-- length;
					continue;						// continue combine into this Block
				}
			}
			head = head.next;
		}
	}

	// FOR DEBUG
	static function iterator():BlockIterator {
		return new BlockIterator(top);
	}

	// simple check for "Subscript out of range"
	public static function check():Bool {
		var cur = top;
		var prev: Block;
		while (cur != NUL) {
			if (Memory.getUI16(cur) != 0) return false; // zero
			if (cur.next == NUL) break;

			prev = cur;
			cur = cur.next;
			if (cur.prev != prev) return false;
		}
		if (cur != bottom) return false;
		return true;
	}
}


private class BlockIterator {

	var head:Block;

	public inline function new(h:Block) head = h;

	public inline function hasNext():Bool return head != Malloc.NUL;

	public inline function next():Block {
		var block = head;
		head = head.next;
		return block;
	}
}