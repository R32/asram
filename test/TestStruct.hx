package;

import mem.Ptr;
import haxe.unit.TestRunner;

enum NsfVer{
	Zero;
	One;
	Two;
	Three;
}

enum NsfSys{
	IsPAL;
	Dual;
}

/**
http://vgmrips.net/wiki/NSF_File_Format
*/
class Nsfhd implements mem.Struct{
	@idx(5) var tag:String;
	@idx var ver:NsfVer;						// test Enum
	@idx var track_count:Int;
	@idx var track_intro_number:Int;
	@idx(2) var data_address:Int;
	@idx(2) var init_address:Int;
	@idx(2) var song_address:Int;
	@idx(32) var title:String;
	@idx(32) var author:String;
	@idx(32) var copyright:String;
	@idx(2) var ntsc:Int;
	@idx(8) var bank:Array<Int>;
	@idx(2) var ntsc_loop_speed:Int;
	@idx var sys:haxe.EnumFlags<NsfSys>;		// test EnumFlags
	@idx var spec:Int;
	@idx(4) var exra:Array<Int>;
}

class EndianDetect implements mem.Struct{
	@idx var littleEndian:Bool;		// 00
	@idx(2, -1) var i:Int;			// 00~01
	@idx(-1) var bigEndian:Bool;	// 01

	public inline function new(){
		ptr = Ram.malloc(CAPACITY);
		i = 1;
	}
}

class TestStruct extends haxe.unit.TestCase{
	function testNsfhd(){
		print("\n");
		var file = haxe.Resource.getBytes("supermario");

		var mario = new Nsfhd(Ram.malloc(file.length));
		Ram.writeBytes(mario.ptr, file.length, file.getData());
		print(mario.toString() + "\n");

		var fake = new Nsfhd(Ram.malloc(Nsfhd.CAPACITY));
		for (key in Nsfhd.ALL_FIELDS()){
			Reflect.setProperty(fake, key, Reflect.getProperty(mario, key));
		}
		assertTrue(mario.ntsc == 0x411A && Nsfhd.CAPACITY == 128 && Ram.memcmp(fake.ptr, mario.ptr, Nsfhd.CAPACITY));

		var endian = new EndianDetect();
		print(endian.toString() + "\n");
		assertTrue(endian.littleEndian == true && endian.bigEndian == false);

		mario.free();
		fake.free();
		endian.free();
		print("chunkfrag: " + @:privateAccess mem.Chunk.fragCount);
	}

	public static function main(){
		var stage = flash.Lib.current.stage;
		stage.scaleMode = flash.display.StageScaleMode.NO_SCALE;
		stage.align = flash.display.StageAlign.TOP_LEFT;
		Ram.select(Ram.create());

		var runner = new TestRunner();
		runner.add(new TestStruct());
		runner.run();
		@:privateAccess{
			TestRunner.tf.textColor = 0xffffff;
		}
	}
}